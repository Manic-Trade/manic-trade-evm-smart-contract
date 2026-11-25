#!/usr/bin/env python3
"""The smoke test on a deployed chain (docs/runbooks/deploy-testnet.md): every way a bet ends, on the live contract.

    python3 script/smoke.py run    --rpc <url> --wallets <wallets.json> --out <log.json>
    python3 script/smoke.py refund --rpc <url> --wallets <wallets.json> --out <log.json>   (an hour after `run`)
    python3 script/smoke.py restore --rpc <url> --wallets <wallets.json> --out <log.json>  (after a failed run)
    python3 script/smoke.py cleanup --rpc <url> --wallets <wallets.json> --out <log.json>  (ends its stranded bets)
    python3 script/smoke.py open --leverage 1000 --side call ...   (one bet, left open; e.g. across an upgrade)
    python3 script/smoke.py settle ...                             (settles the log's open bets, each at its expiry)
    python3 script/smoke.py report --out <log.json> [--explorer <url>] > report.md

It signs and sends the way the backend does. The user signs each order and the stake's EIP-3009 authorisation with
`cast wallet sign`, and a relayer sends the call with `cast send` at once: an open's or a sale's price may be at most 5
seconds old, and `forge script` takes longer than that on a public RPC.

`run` makes these bets and steps, in order:
- **At each leverage:** an open and a settle, as a win and as a loss.
- **The other endings:**
  - a liquidation batch of two;
  - a sale before expiry;
  - the safety refund, whose delay `run` shortens to an hour for one bet (`refund`, an hour later, refunds it and
    restores the delay).
- **The money paths:**
  - a payout deferred to a frozen user, then claimed;
  - the fees swept;
  - `repay` on an empty queue.
- **The breaker:** limit lowered for the test, then a trip, an open refused, the operator's reset, and the limit
  restored.
- **Refused:** a batch mixing two leverages.
- **Timing:** a burst of opens to time the gap between a price's time and its block, and the chain's clock against this
  machine's.

After every transaction it checks the step's own effect (statuses, balances, the books' fields, the breaker), and
everywhere that the contract's token balance equals its books: the pool's total plus the fees pending plus the claimable
payouts.

`--wallets` is a JSON file, kept out of git, giving `cast`'s wallet arguments for each role: deployer (the admin,
operator, guardian and the mock's admin), opener1, opener2, settler1, settler2 and user, e.g.
`{"opener1": ["--account", "manic-testnet-opener-1", "--password-file", "/path/pw"], ...}`, or on anvil
`["--private-key", "0x..."]`. The deployment is read from deployments/<chainId>.json. Only the standard library and
`cast` (Foundry); Python 3.9 or newer.
"""
import argparse
import json
import os
import pathlib
import secrets
import statistics
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
CAST = os.environ.get("CAST", "cast")
BTC = "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43"
PRICE = 9_500_000_000_000  # $95,000 at BTC's exponent, -8: the relayer is the price source
STAKE = 10_000_000  # $10
SMALL = 1_000_000  # $1, the smallest stake, for the timing burst
RECEIVE_TYPEHASH = "0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8"
DOMAIN_TYPE = "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
OPEN_ORDER_TYPE = ("OpenOrder(bytes32 positionId,address user,bytes32 marketId,uint16 leverage,uint8 side,uint64 stake,"
                   "uint16 durationSecs,uint48 notBefore,uint48 deadline)")
SELL_ORDER_TYPE = "SellOrder(bytes32 positionId,uint64 minAmount,uint48 notBefore,uint48 deadline)"
OPEN_GAS, SELL_GAS = 400_000, 300_000  # given, so a time-critical send skips the estimate

OPEN_ORDER = "(bytes32,address,bytes32,uint16,uint8,uint64,uint16,uint48,uint48)"
OPEN_TERMS = "(int64,uint48,uint32,uint16,uint16)"
STAKE_AUTH = "(uint256,uint256,bytes)"
SELL_ORDER = "(bytes32,uint64,uint48,uint48)"
SELL_TERMS = "(int64,uint48,uint64,uint64)"
POOL = "(uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint32,uint32,uint64,uint64,uint64,uint64,uint64,uint64)"
POOL_FIELDS = ["total", "lockedMargin", "openMaxProfit", "totalOwed", "poolFloor", "nextQueueSeq", "nextRepaySeq",
               "openPositions", "owedPositions", "feesPending", "totalClaimable", "transferred", "feesPaid",
               "seedRecovered", "rewardsWithdrawn"]
BREAKER = "(uint64,uint64,uint48,bool,uint32,uint64)"
BREAKER_FIELDS = ["profitOut", "lossIn", "windowStart", "tripped", "windowSecs", "maxNetProfit"]
POSITION = "(address,uint16,uint8,uint8,uint48,uint16,uint64,int64,int64,uint16,uint16,uint16,uint64,uint64)"
POSITION_FIELDS = ["user", "marketIdx", "side", "status", "startTime", "durationSecs", "stake", "entryPrice",
                   "liqPrice", "floorBps", "capBps", "leverage", "owed", "queueSeq"]
MARKET = ("(bytes32,bool,bool,int8,uint8,uint8,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint64,uint64,"
          "uint64,uint16,(uint16,uint32,uint32,bool)[5])")
MARKET_FIELDS = ["marketId", "enabled", "paused", "priceExponent", "entryMaxAgeSecs", "clockSkewSecs", "floorMinBps",
                 "floorMaxBps", "capMinBps", "capMaxBps", "maxSellFeeBps", "sellMinDelaySecs", "sellCutoffSecs",
                 "maxExposureBps", "minStake", "maxStake", "maxTotalOwed", "leverage", "durations"]
OPEN, CLOSED = 1, 3
CALL, PUT = 0, 1


class Failure(Exception):
    """A step that didn't do what it should."""


class Chain:
    """The deployed contract, reached through `cast`."""

    def __init__(self, rpc, wallets):
        self.rpc = rpc
        self.wallets = wallets
        self.chain_id = int(self._cast("chain-id"))
        record = json.loads((ROOT / "deployments" / f"{self.chain_id}.json").read_text())
        self.proxy, self.token = record["proxy"], record["token"]
        self.addr = {role: self._cast("wallet", "address", *args, rpc=False) for role, args in wallets.items()}
        self.errors = self._error_selectors()
        self.domain = self.call("DOMAIN_SEPARATOR()(bytes32)", to=self.token)  # the token's, for EIP-3009
        # The contract's EIP-712 domain, so orders are hashed here, with no RPC between a tick and its send. Checked
        # against the contract's own hashOpenOrder and hashSellOrder below.
        name, version, chain, verifying = self.call("eip712Domain()(bytes1,string,string,uint256,address,bytes32,"
                                                    "uint256[])", json_out=True)[1:5]
        self.order_domain = self.keccak(self.abi_encode(
            "f(bytes32,bytes32,bytes32,uint256,address)", self.keccak_text(DOMAIN_TYPE), self.keccak_text(name),
            self.keccak_text(version), chain, verifying))
        self.open_typehash = self.keccak_text(OPEN_ORDER_TYPE)
        self.sell_typehash = self.keccak_text(SELL_ORDER_TYPE)
        self.gas_price = 2 * int(self._cast("gas-price"))
        self._self_check()

    def _self_check(self):
        o = ["0x" + "11" * 32, self.addr["user"], BTC, 1000, 1, 1_000_000, 60, 1_700_000_000, 1_700_000_060]
        if self.open_digest(o) != self.call(f"hashOpenOrder({OPEN_ORDER})(bytes32)", "(" + ",".join(map(str, o)) + ")"):
            raise Failure("the local OpenOrder hash differs from the contract's")
        s = ["0x" + "22" * 32, 9_700_000, 1_700_000_000, 1_700_000_030]
        if self.sell_digest(s) != self.call(f"hashSellOrder({SELL_ORDER})(bytes32)", "(" + ",".join(map(str, s)) + ")"):
            raise Failure("the local SellOrder hash differs from the contract's")

    def keccak_text(self, text):
        return self._cast("keccak", text, rpc=False)

    def open_digest(self, o):
        struct = self.abi_encode("f(bytes32,bytes32,address,bytes32,uint16,uint8,uint64,uint16,uint48,uint48)",
                                 self.open_typehash, *o)
        return self.keccak("0x1901" + self.order_domain[2:] + self.keccak(struct)[2:])

    def sell_digest(self, s):
        struct = self.abi_encode("f(bytes32,bytes32,uint64,uint48,uint48)", self.sell_typehash, *s)
        return self.keccak("0x1901" + self.order_domain[2:] + self.keccak(struct)[2:])

    def nonce(self, role):
        return int(self._cast("nonce", self.addr[role], "--block", "pending"))

    def _cast(self, *args, rpc=True, check=True):
        cmd = [CAST, *args] + (["--rpc-url", self.rpc] if rpc else [])
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        if check and r.returncode != 0:
            raise Failure(f"cast {' '.join(args[:2])}: {self._why(r.stderr + r.stdout)}")
        return r.stdout.strip()

    def _error_selectors(self):
        abi = json.loads((ROOT / "abi" / "IManicFlashOption.json").read_text())
        abi = abi["abi"] if isinstance(abi, dict) else abi
        names = {}
        for e in abi:
            if e.get("type") == "error":
                sig = e["name"] + "(" + ",".join(i["type"] for i in e["inputs"]) + ")"
                names[self._cast("sig", sig, rpc=False)] = e["name"]
        return names

    def _why(self, text):
        """A revert's error name, from the data in `cast`'s message."""
        for word in text.replace('"', " ").replace(",", " ").split():
            if word.startswith("0x") and len(word) >= 10 and word[:10] in self.errors:
                return f"{self.errors[word[:10]]} ({word[:74]})"
        return " | ".join(text.strip().splitlines()[-3:])[:400] if text.strip() else "no output"

    def call(self, sig, *args, to=None, json_out=False):
        out = self._cast("call", *(["--json"] if json_out else []), to or self.proxy, sig, *map(str, args))
        return json.loads(out) if json_out else out.split(" ")[0]

    def try_call(self, sig, *args, sender):
        """Runs a call without sending it: (True, output) or (False, the error's name)."""
        r = subprocess.run([CAST, "call", self.proxy, sig, *map(str, args), "--from", sender, "--rpc-url", self.rpc],
                           capture_output=True, text=True, timeout=180)
        return (True, r.stdout.strip()) if r.returncode == 0 else (False, self._why(r.stderr + r.stdout))

    def send(self, role, sig, *args, to=None, fast=None):
        """Sends and waits for the receipt. `fast` = (nonce, gas limit): given, so `cast` skips four lookups."""
        extra = []
        if fast:
            extra = ["--nonce", str(fast[0]), "--gas-limit", str(fast[1]), "--gas-price", str(self.gas_price),
                     "--priority-gas-price", "0", "--chain", str(self.chain_id)]
        r = subprocess.run([CAST, "send", "--json", to or self.proxy, sig, *map(str, args), *self.wallets[role],
                            *extra, "--rpc-url", self.rpc], capture_output=True, text=True, timeout=300)
        if r.returncode != 0:
            raise Failure(f"{role} {sig.split('(')[0]}: {self._why(r.stderr + r.stdout)}")
        receipt = json.loads(r.stdout)
        if int(receipt["status"], 16) != 1:
            raise Failure(f"{role} {sig.split('(')[0]}: reverted in {receipt['transactionHash']}")
        return receipt

    def sign(self, role, digest):
        return self._cast("wallet", "sign", "--no-hash", digest, *self.wallets[role], rpc=False)

    def latest_ts(self):
        return int(self._cast("block", "latest", "--field", "timestamp"))

    def block_ts(self, number):
        return int(self._cast("block", str(number), "--field", "timestamp"))

    def keccak(self, hex_data):
        return self._cast("keccak", hex_data, rpc=False)

    def abi_encode(self, sig, *args):
        return self._cast("abi-encode", sig, *map(str, args), rpc=False)

    # --- reads -------------------------------------------------------------------------------------------------------
    def pool(self):
        return dict(zip(POOL_FIELDS, map(int, self.call(f"getPool()({POOL})", json_out=True)[0])))

    def breaker(self):
        v = self.call(f"getBreaker()({BREAKER})", json_out=True)[0]
        return {k: (x if isinstance(x, bool) else int(x)) for k, x in zip(BREAKER_FIELDS, v)}

    def position(self, pid):
        v = self.call(f"getPosition(bytes32)({POSITION},uint48,int64)", pid, json_out=True)
        p = dict(zip(POSITION_FIELDS, v[0]))
        for k in POSITION_FIELDS[1:]:
            p[k] = int(p[k])
        p["endTime"] = int(v[1])
        return p

    def market(self, leverage):
        v = self.call(f"getMarket(bytes32,uint16)({MARKET})", BTC, leverage, json_out=True)[0]
        return dict(zip(MARKET_FIELDS, v))

    def balance(self, who):
        return int(self.call("balanceOf(address)(uint256)", who, to=self.token))

    def claimable(self, who):
        return int(self.call("claimableOf(address)(uint64)", who))

    def snapshot(self):
        s = {"pool": self.pool(), "breaker": self.breaker(), "proxy": self.balance(self.proxy),
             "user": self.balance(self.addr["user"]), "userClaimable": self.claimable(self.addr["user"]),
             "feeRecipient": self.balance(self.recipients()[0])}
        return s

    def recipients(self):
        return self.call("recipients()(address,address)", json_out=True)


class Campaign:
    """The steps, their checks, and the log."""

    def __init__(self, chain, out):
        self.c = chain
        self.out = pathlib.Path(out)
        self.log = json.loads(self.out.read_text()) if self.out.exists() else {"chainId": chain.chain_id,
                                                                               "proxy": chain.proxy, "steps": [],
                                                                               "gaps": [], "state": {}}
        self.lock = threading.Lock()

    # --- logging and checks ------------------------------------------------------------------------------------------
    def record(self, name, receipt=None, checks=(), note="", pid=None):
        step = {"step": name, "note": note, "checks": list(checks), "time": int(time.time())}
        if pid:
            step["id"] = pid
        if receipt:
            step.update(tx=receipt["transactionHash"], block=int(receipt["blockNumber"], 16),
                        gas=int(receipt["gasUsed"], 16))
        with self.lock:
            self.log["steps"].append(step)
            self.save()
        print(f"  ok  {name}" + (f"  {step['tx']}" if receipt else "") + (f"  ({note})" if note else ""), flush=True)

    def save(self):
        self.out.write_text(json.dumps(self.log, indent=1) + "\n")

    def expect(self, cond, what, checks):
        if not cond:
            raise Failure(f"check failed: {what}")
        checks.append(what)

    def books(self, checks):
        """The contract's balance equals its books, and the books balance."""
        p, bal = self.c.pool(), self.c.balance(self.c.proxy)
        books = p["total"] + p["feesPending"] + p["totalClaimable"]
        self.expect(bal == books, f"balance {bal} = total + fees + claimable {books}", checks)
        self.expect(p["lockedMargin"] <= p["total"], "lockedMargin <= total", checks)
        self.expect(p["totalOwed"] == 0 and p["owedPositions"] == 0, "nobody owed", checks)
        return p

    # --- the backend's calls -----------------------------------------------------------------------------------------
    def build_open(self, leverage, side, stake=STAKE, price=PRICE):
        """The `open` call's arguments, signed by the user, at a tick stamped now: (id, tick time, args)."""
        m = self.c.market(leverage)
        rule = m["durations"][0]
        theta = (int(rule[1]) + int(rule[2])) // 2
        user = self.c.addr["user"]
        pid = "0x" + secrets.token_hex(32)
        # The tick's time: the wall clock, a second back (the chain runs behind). From here to the send, nothing goes
        # over the RPC: an open's price may be at most 5 seconds old when it lands.
        now = int(time.time()) - 1
        fields = [pid, user, BTC, leverage, side, stake, int(rule[0]), now, now + 60]
        order = "(" + ",".join(map(str, fields)) + ")"
        terms = f"({price},{now},{theta},{int(m['floorMinBps'])},{int(m['capMaxBps'])})"
        order_sig = self.c.sign("user", self.c.open_digest(fields))
        valid_after, valid_before = now - 60, now + 300
        struct = self.c.abi_encode("f(bytes32,address,address,uint256,uint256,uint256,bytes32)", RECEIVE_TYPEHASH,
                                   user, self.c.proxy, stake, valid_after, valid_before, pid)
        digest = self.c.keccak("0x1901" + self.c.domain[2:] + self.c.keccak(struct)[2:])
        auth = f"({valid_after},{valid_before},{self.c.sign('user', digest)})"
        return pid, now, (order, order_sig, terms, auth)

    def open(self, opener, leverage, side, stake=STAKE, price=PRICE, racy=False):
        """Signs and sends an open; returns the position id and its gap (block time - price time). `racy`: other opens
        run at the same time, so the balance and books checks wait for the end of the burst."""
        user = self.c.addr["user"]
        before = None if racy else self.c.balance(user)
        nonce = self.c.nonce(opener)
        pid, now, args = self.build_open(leverage, side, stake, price)
        r = self.c.send(opener, f"open({OPEN_ORDER},bytes,{OPEN_TERMS},{STAKE_AUTH})", *args, fast=(nonce, OPEN_GAS))
        gap = self.c.block_ts(int(r["blockNumber"], 16)) - now
        checks = []
        p = self.c.position(pid)
        self.expect(p["status"] == OPEN and p["stake"] == stake and p["leverage"] == leverage, "position open", checks)
        self.expect(p["startTime"] == now and p["entryPrice"] == price, "entry time and price as signed", checks)
        if not racy:
            self.expect(self.c.balance(user) == before - stake, f"user paid the stake {stake}", checks)
            self.books(checks)
        side_name = "call" if side == CALL else "put"
        self.record(f"open {side_name} {leverage}x ${stake / 1e6:g} by {opener}", r, checks, f"gap {gap}s", pid=pid)
        with self.lock:
            self.log["gaps"].append({"kind": "open", "gap": gap})
        return pid, gap

    def wait_until(self, ts):
        while self.c.latest_ts() < ts:
            time.sleep(1)

    def settle(self, settler, pid, price, expect_win):
        p = self.c.position(pid)
        self.wait_until(p["endTime"])
        before = self.c.snapshot()
        r = self.c.send(settler, "settle(bytes32,uint16,int64,uint48,bytes32[])", BTC, p["leverage"], price,
                        p["endTime"], f"[{pid}]")
        after, checks = self.c.snapshot(), []
        self.expect(self.c.position(pid)["status"] == CLOSED, "position closed", checks)
        paid = after["user"] - before["user"] + after["userClaimable"] - before["userClaimable"]
        bp, ap = before["pool"], after["pool"]
        self.expect(ap["lockedMargin"] == bp["lockedMargin"] - p["stake"], "its margin released", checks)
        self.expect(ap["openPositions"] == bp["openPositions"] - 1, "one fewer open", checks)
        if expect_win:
            self.expect(paid > p["stake"], f"a right call paid {paid} > stake {p['stake']}", checks)
            self.expect(after["breaker"]["profitOut"] > before["breaker"]["profitOut"] or after["breaker"][
                "windowStart"] != before["breaker"]["windowStart"], "the breaker counted the profit", checks)
        else:
            self.expect(paid < p["stake"], f"a wrong call paid {paid} < stake {p['stake']}", checks)
        self.expect(after["proxy"] == before["proxy"] - (after["user"] - before["user"]),
                    "the contract paid exactly what the user received", checks)
        self.books(checks)
        self.record(f"settle {'win' if expect_win else 'loss'} {p['leverage']}x by {settler}", r, checks,
                    f"paid {paid / 1e6:.6f}")
        return paid

    # --- the campaign ------------------------------------------------------------------------------------------------
    def run(self):
        c = self.c
        print(f"chain {c.chain_id}, proxy {c.proxy}, token {c.token}", flush=True)
        checks = []
        p = self.books(checks)
        self.expect(not c.breaker()["tripped"], "breaker not tripped", checks)
        b = c.breaker()
        # The settings the test changes, kept once: `refund` and `restore` put them back.
        start = self.log["state"].setdefault("start", {"refundDelay": int(c.call("refundDelaySecs()(uint48)")),
                                                       "breakerLimit": b["maxNetProfit"],
                                                       "breakerWindow": b["windowSecs"],
                                                       "openPositions": p["openPositions"]})
        self.record("start: the books balance", checks=checks,
                    note=f"refund delay {start['refundDelay']} s, breaker ${start['breakerLimit'] / 1e6:g} per "
                         f"{start['breakerWindow']} s, {start['openPositions']} open")

        # Money for the user: the deployer is the mock's admin.
        r = c.send("deployer", "mint(address,uint256)", c.addr["user"], 300 * STAKE, to=c.token)
        self.record("mint $300 to the smoke user", r, [f"user {c.addr['user']}"])

        self.clock_lag()
        self.endings()
        self.claim()
        self.breaker_trip()
        self.fees_and_repay()
        self.burst()
        self.refund_setup()
        self.save()
        print("run: every step passed. Run `refund` once the refund bet is an hour past its expiry.", flush=True)

    def clock_lag(self, samples=40):
        """The chain's latest block time against this machine's clock, each read timed from the request's midpoint."""
        lags = []
        for _ in range(samples):
            t0 = time.time()
            ts = self.c.latest_ts()
            t1 = time.time()
            lags.append((t0 + t1) / 2 - ts)
            time.sleep(0.25)
        lags.sort()
        self.log["clockLag"] = {"samples": samples, "p50": round(statistics.median(lags), 2),
                                "p99": round(lags[min(len(lags) - 1, int(len(lags) * 0.99))], 2),
                                "min": round(lags[0], 2), "max": round(lags[-1], 2)}
        self.record("the chain's clock against this machine's", note=f"lag p50 {self.log['clockLag']['p50']}s, "
                                                                     f"max {self.log['clockLag']['max']}s")

    def endings(self):
        """Wins and losses at each leverage, a liquidation batch, a sale, and a refused mixed batch."""
        c = self.c
        win1000, _ = self.open("opener1", 1000, CALL)
        loss1000, _ = self.open("opener2", 1000, CALL)
        win500, _ = self.open("opener1", 500, PUT)
        win100, _ = self.open("opener2", 100, CALL)
        liq_a, _ = self.open("opener1", 1000, CALL)
        liq_b, _ = self.open("opener2", 1000, CALL)
        sold, _ = self.open("opener1", 1000, CALL)

        # The sale: the user signs; the opener prices it 1 bp up and sends at once.
        p = c.position(sold)
        sell_price = PRICE + PRICE // 10_000
        valuation = p["stake"]  # within what it pays at that price (a right call pays at least its floor, 1.1x)
        amount = valuation * 97 // 100  # a 3% early-sell fee, within the 6% cap
        before, nonce = c.snapshot(), c.nonce("opener2")  # every read before the tick
        now = int(time.time()) - 1
        fields = [sold, amount, now, now + 30]
        sig = c.sign("user", c.sell_digest(fields))
        r = c.send("opener2", f"sell({SELL_ORDER},bytes,{SELL_TERMS})", "(" + ",".join(map(str, fields)) + ")", sig,
                   f"({sell_price},{now},{valuation},{amount})", fast=(nonce, SELL_GAS))
        gap = c.block_ts(int(r["blockNumber"], 16)) - now
        after, checks = c.snapshot(), []
        self.expect(c.position(sold)["status"] == CLOSED, "the sold position closed", checks)
        got = after["user"] - before["user"]
        fee = (amount - p["stake"]) * 2 // 100 if amount > p["stake"] else 0
        self.expect(got == amount - fee, f"the user got the sale amount {amount} less the winner fee {fee}", checks)
        self.books(checks)
        self.record("sell call 1000x before expiry by opener2", r, checks, f"got {got / 1e6:.6f}, gap {gap}s", pid=sold)
        self.log["gaps"].append({"kind": "sell", "gap": gap})

        # The liquidation: a tick 1% down touches both calls' lines; one batch.
        pa, pb = c.position(liq_a), c.position(liq_b)
        tick = max(pa["startTime"], pb["startTime"])
        self.wait_until(tick)
        before = c.snapshot()
        r = c.send("settler2", "liquidate(bytes32,uint16,int64,uint48,bytes32[])", BTC, 1000, PRICE * 99 // 100,
                   tick, f"[{liq_a},{liq_b}]")
        after, checks = c.snapshot(), []
        self.expect(all(c.position(x)["status"] == CLOSED for x in (liq_a, liq_b)), "both liquidated", checks)
        self.expect(after["user"] == before["user"], "nothing paid to the user", checks)
        self.expect(after["breaker"]["lossIn"] - before["breaker"]["lossIn"] == pa["stake"] + pb["stake"]
                    or after["breaker"]["windowStart"] != before["breaker"]["windowStart"],
                    "the breaker counted both stakes as kept", checks)
        self.expect(after["pool"]["feesPending"] > before["pool"]["feesPending"], "the loser fees accrued", checks)
        self.books(checks)
        self.record("liquidate a batch of 2 calls at 1000x by settler2", r, checks)

        # A batch mixing two leverages is refused: 1000x's settle with the 500x bet in it.
        pw = c.position(win1000)
        self.wait_until(pw["endTime"])
        ok, why = c.try_call("settle(bytes32,uint16,int64,uint48,bytes32[])", BTC, 1000, PRICE, pw["endTime"],
                             f"[{win1000},{win500}]", sender=c.addr["settler1"])
        checks = []
        self.expect(not ok and "ConfigMismatch" in why, f"refused: {why}", checks)
        self.record("a settle batch mixing 1000x and 500x is refused", checks=checks, note=why)

        # The settles, each at its expiry.
        up, down = PRICE + PRICE // 10_000, PRICE - PRICE // 10_000
        self.settle("settler1", win1000, up, True)
        self.settle("settler2", loss1000, down, False)
        self.settle("settler1", win500, down, True)  # a put wins when the price falls
        self.settle("settler2", win100, up, True)

    def claim(self):
        """A frozen winner: the payout waits in claimable, and anyone claims it for them once unfrozen."""
        c = self.c
        pid, _ = self.open("opener1", 500, CALL)
        r = c.send("deployer", "freeze(address)", c.addr["user"], to=c.token)
        self.record("freeze the user (the mock's admin)", r, [])
        before = c.claimable(c.addr["user"])
        paid = self.settle("settler1", pid, PRICE + PRICE // 10_000, True)
        checks = []
        owed = c.claimable(c.addr["user"]) - before
        self.expect(owed == paid and owed > 0, f"the payout {owed} waits in claimable", checks)
        self.record("the frozen winner's payout deferred", checks=checks)
        r = c.send("deployer", "unfreeze(address)", c.addr["user"], to=c.token)
        self.record("unfreeze the user", r, [])
        before_bal = c.balance(c.addr["user"])
        r = c.send("settler2", "claim(address)", c.addr["user"])
        checks = []
        self.expect(c.claimable(c.addr["user"]) == 0, "claimable emptied", checks)
        self.expect(c.balance(c.addr["user"]) - before_bal == owed, f"the user received {owed}", checks)
        self.books(checks)
        self.record("claim for the user, by anyone (settler2)", r, checks)

    def breaker_trip(self):
        """The limit lowered to $1; a win trips it; an open is refused; the operator resets; the limit restored."""
        c = self.c
        start = self.log["state"]["start"]
        r = c.send("deployer", "resetBreaker()")
        self.record("reset the breaker's window (operator)", r, [])
        r = c.send("deployer", "setBreaker(uint64,uint32)", 1_000_000, start["breakerWindow"])
        checks = []
        self.expect(c.breaker()["maxNetProfit"] == 1_000_000, "limit $1 for the test", checks)
        self.record("lower the breaker's limit to $1 (admin)", r, checks)
        pid, _ = self.open("opener2", 1000, CALL)
        self.settle("settler2", pid, PRICE + PRICE // 1_000, True)  # 10 bp up: more than $1 of profit
        checks = []
        self.expect(c.breaker()["tripped"], "the breaker tripped", checks)
        self.record("a win over the limit trips the breaker", checks=checks)
        # An open, signed and fresh, is refused while tripped: run it without sending.
        _, _, args = self.build_open(1000, CALL)
        ok, why = c.try_call(f"open({OPEN_ORDER},bytes,{OPEN_TERMS},{STAKE_AUTH})", *args, sender=c.addr["opener1"])
        checks = []
        self.expect(not ok and "BreakerTripped" in why, f"an open is refused: {why}", checks)
        self.record("while tripped, an open is refused", checks=checks, note=why)
        r = c.send("deployer", "resetBreaker()")
        checks = []
        self.expect(not c.breaker()["tripped"], "reset", checks)
        self.record("the operator resets the breaker", r, checks)
        r = c.send("deployer", "setBreaker(uint64,uint32)", start["breakerLimit"], start["breakerWindow"])
        b, checks = c.breaker(), []
        self.expect(b["maxNetProfit"] == start["breakerLimit"] and b["windowSecs"] == start["breakerWindow"],
                    f"restored: ${b['maxNetProfit'] / 1e6:g} per {b['windowSecs']} s", checks)
        self.record("restore the breaker's limit (admin)", r, checks)

    def fees_and_repay(self):
        c = self.c
        before = c.snapshot()
        r = c.send("settler1", "sweepFees()")
        after, checks = c.snapshot(), []
        fees = before["pool"]["feesPending"]
        self.expect(after["pool"]["feesPending"] == 0, "fees pending emptied", checks)
        self.expect(after["feeRecipient"] - before["feeRecipient"] == fees, f"the fee recipient got {fees}", checks)
        self.books(checks)
        self.record("sweep the fees, by anyone (settler1)", r, checks, f"{fees / 1e6:.6f}")
        ok, out = c.try_call("repay(uint256)(uint256)", 10, sender=c.addr["settler1"])
        r = c.send("settler1", "repay(uint256)", 10)
        checks = []
        self.expect(ok and out == "0", "repay finds no IOU (none can form with the open gate at 100%) and returns 0", checks)
        self.books(checks)
        self.record("repay on an empty queue, by anyone", r, checks)

    def burst(self, per_opener=6):
        """$1 opens from both openers at once, to time the gaps; then one liquidation batch ends them all."""
        c, ids, errors = self.c, [], []

        def worker(opener):
            for _ in range(per_opener):
                try:
                    pid, _ = self.open(opener, 1000, CALL, stake=SMALL, racy=True)
                    ids.append(pid)
                except Failure as e:  # noted, not fatal: the burst measures timing
                    errors.append(str(e))

        threads = [threading.Thread(target=worker, args=(o,)) for o in ("opener1", "opener2")]
        [t.start() for t in threads]
        [t.join() for t in threads]
        positions = [c.position(x) for x in ids]
        tick = max(p["startTime"] for p in positions)
        checks = []
        self.books(checks)  # once every burst open has landed
        self.expect(tick <= min(p["endTime"] for p in positions), "one tick inside every bet's life", checks)
        self.wait_until(tick)
        before = c.snapshot()
        r = c.send("settler1", "liquidate(bytes32,uint16,int64,uint48,bytes32[])", BTC, 1000, PRICE * 99 // 100,
                   tick, "[" + ",".join(ids) + "]")
        after = c.snapshot()
        self.expect(all(c.position(x)["status"] == CLOSED for x in ids), f"all {len(ids)} liquidated", checks)
        self.expect(after["pool"]["openPositions"] == before["pool"]["openPositions"] - len(ids), "none left", checks)
        self.books(checks)
        self.record(f"liquidate the burst's {len(ids)} bets in one batch by settler1", r, checks,
                    f"{len(errors)} burst opens refused" + (f": {errors[0][:120]}" if errors else ""))
        self.log["burstErrors"] = errors

    def refund_setup(self):
        """A bet nobody ends; once expired, the refund delay shortened to an hour (the least allowed)."""
        c = self.c
        pid, _ = self.open("opener2", 100, CALL)
        p = c.position(pid)
        self.wait_until(p["endTime"])
        old = self.log["state"]["start"]["refundDelay"]
        r = c.send("deployer", "setRefundDelay(uint48)", 3600)
        checks = []
        self.expect(int(c.call("refundDelaySecs()(uint48)")) == 3600, "refund delay 1 h for the test", checks)
        self.record("shorten the refund delay to 1 h (admin)", r, checks, f"was {old} s")
        ok, why = c.try_call("refundExpired(bytes32[])(uint256)", f"[{pid}]", sender=c.addr["settler2"])
        checks = []
        self.expect(not ok and "RefundTooEarly" in why, f"not yet: the refund is refused, {why}", checks)
        self.record("before the delay, the refund is refused", checks=checks, note=why)
        self.log["state"]["refund"] = {"id": pid, "endTime": p["endTime"], "oldDelay": old,
                                       "dueAt": p["endTime"] + 3600}

    def refund(self):
        c, s = self.c, self.log["state"]["refund"]
        self.wait_until(s["dueAt"])
        before = c.snapshot()
        r = c.send("settler2", "refundExpired(bytes32[])", f"[{s['id']}]")
        after, checks = c.snapshot(), []
        self.expect(c.position(s["id"])["status"] == CLOSED, "refunded and closed", checks)
        self.expect(after["user"] - before["user"] == STAKE, f"the user got the stake {STAKE} back", checks)
        self.books(checks)
        self.record("refund the bet an hour past its expiry, by anyone (settler2)", r, checks)
        r = c.send("deployer", "setRefundDelay(uint48)", s["oldDelay"])
        checks = []
        self.expect(int(c.call("refundDelaySecs()(uint48)")) == s["oldDelay"], f"restored to {s['oldDelay']} s",
                    checks)
        self.record("restore the refund delay (admin)", r, checks)
        checks = []
        p = self.books(checks)
        n = self.log["state"]["start"]["openPositions"]
        self.expect(p["openPositions"] == n, f"no bet of the test left open ({n} open, as at the start)", checks)
        self.record("end: the books balance, nothing of the test left open", checks=checks)
        self.save()

    def open_one(self, leverage, side):
        """One bet, left open: for a bet that spans an upgrade or a quick check by hand."""
        pid, gap = self.open("opener1", leverage, CALL if side == "call" else PUT)
        p = self.c.position(pid)
        print(f"opened {pid}, expires at {p['endTime']}", flush=True)

    def settle_open(self):
        """Settles every bet this log opened that is still open, each at its expiry, 1 bp in its favour."""
        n = 0
        for s in list(self.log["steps"]):
            if s.get("id") and s["step"].startswith("open"):
                p = self.c.position(s["id"])
                if p["status"] == OPEN:
                    up = p["side"] == CALL
                    price = p["entryPrice"] + p["entryPrice"] // 10_000 * (1 if up else -1)
                    self.settle("settler1", s["id"], price, True)
                    n += 1
        print(f"settled {n} bet(s)", flush=True)

    def cleanup(self):
        """Ends every bet this log opened that is still open (after a run that stopped partway): one liquidation batch
        per market and side, at a tick inside every bet's life that touches every line."""
        c, groups = self.c, {}
        for s in self.log["steps"]:
            if s.get("id") and s["step"].startswith("open"):
                p = c.position(s["id"])
                if p["status"] == OPEN:
                    groups.setdefault((p["leverage"], p["side"]), []).append((s["id"], p))
        for (leverage, side), bets in sorted(groups.items()):
            while bets:
                first_end = min(p["endTime"] for _, p in bets)
                batch = [(i, p) for i, p in bets if p["startTime"] <= first_end]
                bets = [(i, p) for i, p in bets if p["startTime"] > first_end]
                tick = max(p["startTime"] for _, p in batch)
                price = PRICE * 99 // 100 if side == CALL else PRICE * 101 // 100
                self.wait_until(tick)
                r = c.send("settler1", "liquidate(bytes32,uint16,int64,uint48,bytes32[])", BTC, leverage, price, tick,
                           "[" + ",".join(i for i, _ in batch) + "]")
                checks = []
                self.expect(all(c.position(i)["status"] == CLOSED for i, _ in batch), "all ended", checks)
                self.books(checks)
                self.record(f"cleanup: liquidate {len(batch)} stranded bet(s) at {leverage}x", r, checks)
        checks = []
        self.books(checks)
        self.record("cleanup done: the books balance", checks=checks, note=f"{c.pool()['openPositions']} open")

    def restore(self):
        """After a run that failed partway: puts back the settings the test changes, and clears a trip."""
        c, start = self.c, self.log["state"]["start"]
        if c.breaker()["tripped"]:
            self.record("reset the tripped breaker (operator)", c.send("deployer", "resetBreaker()"), [])
        b = c.breaker()
        if (b["maxNetProfit"], b["windowSecs"]) != (start["breakerLimit"], start["breakerWindow"]):
            r = c.send("deployer", "setBreaker(uint64,uint32)", start["breakerLimit"], start["breakerWindow"])
            self.record("restore the breaker's limit (admin)", r, [])
        if int(c.call("refundDelaySecs()(uint48)")) != start["refundDelay"]:
            r = c.send("deployer", "setRefundDelay(uint48)", start["refundDelay"])
            self.record("restore the refund delay (admin)", r, [])
        b, checks = c.breaker(), []
        self.expect(not b["tripped"] and b["maxNetProfit"] == start["breakerLimit"] and b["windowSecs"] ==
                    start["breakerWindow"], "the breaker as at the start", checks)
        self.expect(int(c.call("refundDelaySecs()(uint48)")) == start["refundDelay"], "the refund delay as at the start",
                    checks)
        self.record("restored", checks=checks)


def report(log, explorer=None):
    """The log as a Markdown report; with `explorer` (its base URL), each transaction links to it."""
    gaps = sorted(g["gap"] for g in log["gaps"])
    lines = [f"# Smoke test, chain {log['chainId']}", "", f"Contract `{log['proxy']}`.", "",
             "| # | Step | Tx | Gas | Notes |", "|---|---|---|---:|---|"]
    for i, s in enumerate(log["steps"], 1):
        tx = ""
        if s.get("tx"):
            short = f"{s['tx'][:10]}…{s['tx'][-4:]}"
            tx = f"[`{short}`]({explorer.rstrip('/')}/tx/{s['tx']})" if explorer else f"`{short}`"
        lines.append(f"| {i} | {s['step']} | {tx} | {s.get('gas', ''):,} | {s['note']} |" if s.get("gas") else
                     f"| {i} | {s['step']} | {tx} | | {s['note']} |")
    n_checks = sum(len(s["checks"]) for s in log["steps"])
    failures = log.get("failures", [])
    lines += ["", f"{len(log['steps'])} steps, {sum(1 for s in log['steps'] if s.get('tx'))} transactions, "
                  f"{n_checks} checks passed" + (f"; {len(failures)} FAILED:" if failures else ", none failed.")]
    lines += [f"- {f}" for f in failures]
    if gaps:
        p99 = gaps[min(len(gaps) - 1, int(len(gaps) * 0.99))]
        lines += ["", f"Gap from a price's time to its block, {len(gaps)} opens and sales: p50 "
                      f"{statistics.median(gaps)} s, p99 {p99} s, max {gaps[-1]} s (each price stamped a second "
                      f"behind this machine's clock)."]
    if "clockLag" in log:
        cl = log["clockLag"]
        lines += [f"The chain's latest block behind this machine's clock: p50 {cl['p50']} s, max {cl['max']} s "
                  f"({cl['samples']} samples)."]
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["run", "refund", "restore", "cleanup", "open", "settle", "report"])
    ap.add_argument("--leverage", type=int, default=1000, help="open: the market's leverage")
    ap.add_argument("--side", choices=["call", "put"], default="call", help="open: the bet's side")
    ap.add_argument("--rpc")
    ap.add_argument("--wallets")
    ap.add_argument("--out", required=True)
    ap.add_argument("--explorer", help="report: the explorer's base URL, to link each transaction")
    a = ap.parse_args()
    if a.command == "report":
        sys.stdout.write(report(json.loads(pathlib.Path(a.out).read_text()), a.explorer))
        return
    chain = Chain(a.rpc, json.loads(pathlib.Path(a.wallets).read_text()))
    camp = Campaign(chain, a.out)
    try:
        {"run": camp.run, "refund": camp.refund, "restore": camp.restore, "cleanup": camp.cleanup,
         "open": lambda: camp.open_one(a.leverage, a.side), "settle": camp.settle_open}[a.command]()
    except Failure as e:
        camp.log.setdefault("failures", []).append(str(e))
        camp.save()
        sys.exit(f"FAIL: {e}")


if __name__ == "__main__":
    main()
