# SMC Rule-Based Trading Bot (MT5 / MQL5 + Python reference)

A complete, rule-based implementation of the smart-money/liquidity strategy in
sections 1-15 of the specification, plus the addendum (A1-A10, phases 6-7).

**DEMO BY DEFAULT.** `InpLiveTradingEnabled=false`. In paper mode the EA logs
signals and reason codes but sends no orders.

---

## 1. What is implemented

| Phase | Deliverable | Files |
|---|---|---|
| 1 | NY time / DST / sessions; structure engine (swings, BOS, sweeps, strong/weak, ranges, premium/discount, IRL/ERL) | `SMC_Time.mqh`, `SMC_Types.mqh`, `SMC_Structure.mqh`, `python/smc_engine.py`, `python/smc_time.py` |
| 2 | POI detection/mitigation/refinement/eligibility; multi-TF bias | `SMC_POI.mqh`, `SMC_Bias.mqh`, `python/smc_poi.py` |
| 3 | Setups A/B/C/D; probability score | `SMC_Setups.mqh` |
| 4 | Trade management, risk, news filter, persistence, logger | `SMC_Trade.mqh`, `SMC_Risk.mqh`, `SMC_Logger.mqh` |
| 5 | Main EA, all inputs, report scripts | `SMC_Bot.mq5`, `python/report.py` |
| 6 | CLOSE_LEVEL POI model, top-down routine, day-type classifier, Setups E/F, range expansion | `SMC_CloseLevel.mqh`, `SMC_TopDown.mqh`, `python/smc_addendum.py` |
| 7 (optional) | MSNR key levels, storyline, Setup M | `MSNR_Levels.mqh`, `MSNR_Storyline.mqh`, `MSNR_SetupM.mqh`, `python/msnr.py` |

### Architecture notes

* One `CStructure` + one `CPOIEngine` + one `CCloseLevelEngine` instance per
  timeframe (MN1, W1, D1, H4, H1, M30, M15, M5). Each engine is fed only
  **closed** bars; the forming bar is never processed, so nothing repaints.
* `OnTick` processes a new entry-TF bar for structure updates; tick-level code
  only manages pending cancellation and open positions. Top-down tasks run on
  new MN1/W1/D1 bars via `OnNewEntryBar()`.
* All price thresholds use `_Point` or ATR multiples. The documented pip size is
  10 points for GBPUSD; XAUUSD uses the ATR-based limits and `InpGoldPipSize`.
* The EA writes every decision with a reason code to `decisions_log.csv` and
  `Print()`. Magic numbers isolate its own orders.

---

## 2. Install (Windows / MetaTrader 5)

1. Copy `MQL5/Include/SMC/*.mqh` into
   `<MT5 data folder>/MQL5/Include/SMC/`.
2. Copy `MQL5/Experts/SMC_Bot/SMC_Bot.mq5` into
   `<MT5 data folder>/MQL5/Experts/SMC_Bot/`.
3. Copy `news.csv` (if used) into `<MT5 data folder>/MQL5/Files/`.
   Format: `datetime,currency,impact` (impact `3` = high/red).
4. Open MetaEditor and compile `SMC_Bot.mq5` (F7). Or run:

   ```powershell
   .\deploy.ps1 -Compile
   ```

   which copies all sources into the terminal folder and compiles every `.mq5`,
   writing logs to `data/compile_*.log`.
5. Attach `SMC_Bot` to a GBPUSD or XAUUSD M15 chart (one instance per symbol).
   Leave `InpLiveTradingEnabled=false` for forward testing.

Both `GBPUSD` and `XAUUSD` are supported by default; `EURUSD` can be used as an
input but ADR/R:R must be re-checked (the source notes EURUSD's smaller ADR).

---

## 3. Python cross-check and tests

```powershell
# unit tests (swings, BOS, strong points, ranges, session/DST, POI,
# close levels, day types, range expansion, MSNR)
python -m unittest discover -s tests -v

# replay a CSV through the reference structure engine
python python/smc_engine.py --csv data/GBPUSD_M15.csv

# tabular backtest (existing reference backtester)
python python/backtest.py --symbol XAUUSD --range-tf H4 --stops relaxed `
    --csv data/reports/XAUUSD_trades.csv --json data/reports/XAUUSD.json

# full acceptance report: A/B POI models, Asia filter, score sweep,
# spread/SL sensitivities, Monte Carlo, walk-forward
python python/report.py --symbol GBPUSD --range-tf H1 --runs 1000
python python/report.py --symbol XAUUSD --range-tf H4 --runs 1000
```

The Python engine and the MQL5 engine are 1:1 ports; feed the same CSV bars to
both and compare the printed ranges/BOS counts.

---

## 4. Input groups (defaults)

* **Timeframes**: D1 / H4 / H1 / M15 / M5 (all inputs).
* **Sessions (NY)**: Asia 17:00-00:00 (ICT preset) or 19:00-00:00
  (`InpAsiaStandardPreset`), LKZ 02:00-05:00, NYKZ 07:00-10:00,
  `InpEntryGraceMinutes=30`.
* **Structure**: `SwingLen=1`, `BOSByClose=true`, `EqualTol=0.1*ATR14`,
  `RangeHistory=3`, strong-point invalidation by close.
* **POI**: `MinWickRatio=0.5`, `MaxPOIHeightATR=0.6`, `EntryLevel=0.5`,
  `MinLiquidityPools=1`, `SkipFirstPullbackPOI=true`, `RequireHTFPOI=true`.
* **Stops/targets**: GBPUSD SL 2-5 pips; XAUUSD 0.15-0.5 ATR(M15);
  `TP1=40%` at 1.5R; BE after TP1; runner to ERL, max 15R; `SL=POI edge +
  spread*1 + buffer`.
* **Risk**: 0.5% per trade (or fixed money), daily loss 3%, weekly loss 6%,
  max open risk 1.5%, max trades/day 3, max consecutive losses 3, max open
  trades 2, equity stop 20%.
* **Score**: full >=7 (mult 1.0), 5-6 (0.75), 3-4 (0.5), <3 no trade;
  provisional / Setup D risk reduced (0.25 / 0.5).
* **Filters**: `AsiaTrendMax=0.65`, `MaxSpreadPoints=30`, `NewsBufferMin=30`.
* **Addendum**: `InpPOIModel` = LEGACY (0, default) / CLOSE_LEVEL (1);
  `InpSLMode` = TIGHT (0, default) / STRONG_POINT (1);
  `InpEnableMSNR=false`; `InpEnablePingPong=false`; `InpOneSetupPerDay=false`.

---

## 5. Testing and acceptance workflow (section 13)

1. **MT5 Strategy Tester**: "Every tick based on real ticks", >= 3 years, both
   symbols, realistic spread/slippage/commission. Run `LEGACY` and
   `CLOSE_LEVEL` as an A/B on identical data and report both.
2. **Per-setup report**: `python/report.py` splits by setup, session, weekday,
   score bucket and Asia-filter on/off, reporting trades, win rate, average R,
   expectancy, profit factor, max drawdown and longest losing streak.
3. **Robustness**: 1000-run Monte Carlo shuffle, spread +50%, 1-pip SL widening.
   The tight 2-5 pip stop is fragile — check these results carefully.
4. **Walk-forward**: 12-month train / 3-month test windows.
5. **Go-live gate (suggested, not enforced)**: profit factor > 1.3, expectancy
   > 0.2R after costs, drawdown within tolerance, stable across years, and at
   least 30 days of demo forward testing whose logs match the backtest.

Current reference results on the bundled data (Setup A, relaxed stops,
2024-2026) are **not** gate-passing: XAUUSD H4 is the only positive cell
(PF ~1.29, 21 trades). Do not enable live trading on this evidence.

---

## 6. Regenerated acceptance results (verify.py)

`python python\verify.py` regenerates both reports and checks every fix item.

* **Monte Carlo** (1000 runs): total R is bootstrapped **with replacement**
  (XAUUSD H4: P05 -10.08R, P50 +1.57R, P95 +19.95R); max DD comes from
  shuffling the realised trade order (P05 3.92R, P50 5.87R, P95 7.90R).
  Previously all percentiles were identical because a shuffle preserves the sum.
* **Min score** is wired into both the EA (`g_cfg.minScore`, web input and
  `InpScoreMin`) and the backtester (`score_min`, section-9 10-item score).
  XAUUSD H4 score buckets: high(5-6) = 3, full(>=7) = 18. `SCORE_MIN_3` and
  `SCORE_MIN_5` are legitimately identical because the lowest observed score
  is 5; `SCORE_MIN_7` gives 18 trades and `SCORE_MIN_9` gives 6.
* **CLOSE_LEVEL debug** (`data/reports/closelevel_debug.json`): 32,720 levels
  created, 32,435 rejected at the `ob_zone` filter, 141 at `ob_above_irl`,
  132 at `ob_below_entry`, 9 at `ob_risk`; 3 orders armed, 2 filled. The thin
  close-level band rarely satisfies the range-zone filter, which explains the
  low trade count.
* **History span**: bundled data is 2024-01-02 to 2026-11-18 = **2.88 years**,
  i.e. slightly short of the requested 3 years. This is reported honestly; add
  more exported history before claiming a 3-year test.
* **95% CI on average R** (normal approximation):
  XAUUSD H4 baseline +0.141R, CI [-0.787, +1.069] (crosses zero);
  GBPUSD H1 -0.567R, CI [-2.232, +1.098]. Both have **N<200 → inconclusive**
  in `summary.csv`.

## 7. Dashboard live controls

The dashboard writes `SMC_bot_config.csv`; the EA reads it every **5 s** and
writes `SMC_bot_status.csv` and `SMC_bot_equity.csv` on the same timer.
The badge shows **EA offline** only after **30 s** without a heartbeat.
Panels: runtime settings, kill switch (cancels pendings, closes positions and
halts; requires password + confirmation), decisions feed (5 s refresh), live
equity chart, and backtest report/Monte Carlo tables.

---

## 8. Phase-by-phase assumptions, added parameters, limitations

### Phase 1
* **Assumptions**: closed bars only; BOS uses closes and marks all older broken
  swings but emits one event per bar; sweeps are frozen when a swing confirms;
  ATR is a simple mean of true ranges (period configurable).
* **Parameters added**: `InpSwingLen`, `InpBOSByClose`, `InpEqualTolATR`,
  `InpATRPeriod`, `InpRangeHistory`, `InpStrongInvalidateByClose`, broker GMT
  offsets / DST mode.
* **Limitations**: session DST uses the broker's configured DST calendar;
  auto-offset sampling is disabled in the tester. Seconds/M1 level marking is
  not supported.

### Phase 2
* **Assumptions**: a bearish OB is the last bullish candle before a down
  displacement; a breaker flips on a body close through the far edge; a POI is
  mitigated when any later candle overlaps its zone.
* **Parameters added**: `InpMinWickRatio`, `InpOBBodyOnly`,
  `InpMaxPOIHeightATR`, `InpEntryLevel`, `InpUseBodyWhenWick`,
  `InpSkipFirstPullbackPOI`, `InpMinLiquidityPools`, `InpRequireHTFPOI`,
  `InpTrendToleranceATR`, weekly-agree switch.
* **Limitations**: trendlines are counted as liquidity pools only, never as
  entry signals; refinement requires an explicit lower-TF engine to be wired.

### Phase 3
* **Assumptions**: the ambiguous TP1 rule "max(1.5R, nearest opposite internal
  swing/FVG), closer in R terms but at least 1R" is implemented as: use the
  nearer of 1.5R and the internal target when that target is >= 1R, otherwise
  1.5R. Pip size is 10 points for non-gold symbols.
* **Parameters added**: buffer/spread multipliers, preferred SL min/max pips,
  `InpMaxSLPoints`, `InpSLAboveStrongHigh`, `InpTP1_R`, `InpERLOffsetPoints`,
  `InpMaxTargetR`, `InpSweepMinPoints`, `InpSweepToBOSMaxBars`,
  `InpPendingExpiryBars`, score thresholds.
* **Limitations**: Setup D is intentionally disabled by default; Setup M's
  +2 combine bonus is applied in `score` but position de-duplication with A-C
  is left to the caller.

### Phase 4
* **Assumptions**: risk sizing uses tick value/tick size; open risk uses each
  position's SL distance; news CSV impact 3 blocks entries; state is persisted
  in MetaTrader global variables.
* **Parameters added**: all risk inputs, `InpNewsFilePath`, `InpNewsBufferMin`,
  `InpMaxSpreadPoints`, `InpMagic`, `InpLogFile`, `InpLiveTradingEnabled`.
* **Limitations**: the news CSV must be pre-populated; correlation guard uses
  a simple per-symbol count, not a regression-based correlation estimate.

### Phase 5
* **Assumptions**: one EA instance per symbol; each instance owns its own
  magic number and never touches other orders; `OnTester()` exposes PF for
  optimisation.
* **Parameters added**: execution inputs (slippage, bars to load, debug log).
* **Limitations**: pending-order fill-time logging ("minutes after KZ start")
  is stored in a global variable but not yet emitted as a dedicated CSV column.

### Phase 6
* **Assumptions**: close levels use closing-price peaks/troughs only; a touch
  is any candle spanning the level; SBR/RBS flips use body closes; the
  top/bottom rule sends the extreme level to the limit and the top level to
  confirmation entries. The Asia day-type classifier runs at NY midnight.
* **Parameters added**: `InpPOIModel`, `InpSLMode`, `InpLevelBandPoints`,
  `InpMinLevelTF`, `InpHTFConflictTolerancePoints`, `InpClusterPoints`,
  `InpMaxRefinePips`, `InpMaxRefineATR`, `InpGoldMaxSLPips`,
  `InpGoldPipSize`, `InpRequireWeeklyAgree`, `InpCounterBreakTFs`,
  `InpOneSetupPerDay`, `InpNoRunnerIfNoExpansion`, `InpTradeNewsDay`,
  `InpNewsDayWindowStart/End`, `InpSweepEarlyMinutes`, `InpGraceMinutes`,
  `InpNoEntryAfterHourNY`, `InpTradeAgainstBiasAsia`, `InpSLExtraPoints`,
  `InpConfirmRiskMult`, `InpRiskReduceFactor`.
* **Limitations**: monthly/weekly "next POI" is stored as the nearest level
  price above/below the period open; gold maximum SL in pips is exposed as an
  input but the Python sensitivity test approximates it via R-cost.

### Phase 7 (optional)
* **Assumptions**: Classic V/A level price is the CLOSE of the first candle;
  OCL is used when the engulf does not occur; a QM requires Classic A -> RBS ->
  RBS broken; storylines are limited to D1/H4, W1/D1 and MN1/W1.
* **Parameters added**: `InpEnableMSNR`, `InpMSNRMinScore`,
  `InpMSNRSLBufferPoints`, `InpMSNR_TP1/2/3_Percent`, `InpMinGapPoints`,
  `InpQMSLBufferPoints`, `InpRequireTurtleSoup`, `InpProtectedRetracePct`,
  `InpAllowFreshOnHTF`, `InpLastLiquidityRequired`.
* **Limitations**: GBO is not implemented (not explained in the source); Setup
  M is aggressive and must pass `msnrScore >= InpMSNRMinScore`.

---

## 9. Web management dashboard (run)

A local control panel lets you toggle paper/live mode, change risk, spread,
score and trade-count limits, inspect decisions and reports, and recompile the
EA — without recompiling for parameter changes.

```powershell
cd C:\Users\Student\SMC_Bot
powershell -ExecutionPolicy Bypass -File .\run_web.ps1 -Password "choose-one"
# open http://127.0.0.1:8020
```

The dashboard writes `<MT5 common>\Files\SMC_bot_config.csv`; the EA reads it
every 60 s and writes `SMC_bot_status.csv` back (heartbeat, bias, positions,
equity). Set `SMC_MT5_FILES` to override the folder and `SMC_WEB_PASSWORD` for
the API password. Bind to `127.0.0.1` only unless you add TLS/authentication in
front — the API password is sent in the `X-SMC-Password` header.

Runtime overrides: `enabled`, `live`, `risk_percent`, `max_spread`,
`max_trades`, `score_min`. Everything else stays an EA input.

---

## 10. Known gaps and contradictions in the sources (A10)

* Some lessons say 2-5 pip stops; another says a stop above the strong high
  gives a higher win rate with lower R:R. Both are supported via `InpSLMode`.
* Earlier lessons use wick/50% levels and LTF ranges for entries; later ones
  drop the 50% level and use ranges only for direction. Both are supported via
  `InpPOIModel`.
* "London makes the high or low of the day 95% of the time" is an unverified
  claim. The EA logs London high/low and the day's extreme; report the hit rate
  per symbol/day type before relying on it.
* GBO, CRT, hidden liquidity, inducement types and advanced liquidity are named
  but not explained in the sources. They are **not** implemented.
* This methodology is a discretionary approximation. Tight stops are sensitive
  to spread, slippage and broker feed differences. Past performance does not
  guarantee future results. Forward-test on demo first. **This is not financial
  advice.**
