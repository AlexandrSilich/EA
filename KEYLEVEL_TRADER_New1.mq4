//+------------------------------------------------------------------+
//|                                      KEYLEVEL_TRADER_New1.mq4   |
//|          Smart Exit Engine: SAR Betrayal + Momentum Death        |
//|          + Elastic ATR Trailing + Volatility Pulse Filter        |
//|          Based on KEYLEVEL_TRADER V1.3                           |
//|          NEW: Intelligent early exit, no classic SL waiting      |
//|          v2.1: Fixed VolatilityATR threshold, SARBetrayal>=2,    |
//|               ElasticTrailing uses order TF (not hardcoded M15)  |
//+------------------------------------------------------------------+
#property copyright "KEYLEVEL TRADER New1 Strategy"
#property link      ""
#property version   "2.10"
#property strict

// =========================================================
// INPUT PARAMETERS
// =========================================================

// --- Risk & Equity Management ---
extern bool   UseDailyEquityTarget     = true;
extern double DailyProfitTargetPercent = 5.0;
extern int    MaxCountCircles          = 2;

// --- Trade Management ---
extern int    MagicNumber      = 20260629;
extern int    Slippage         = 3;
extern double MaxSpreadPips    = 3.0;
extern int    MaxHedgeOrders   = 1;

// =========================================================
// === SMART EXIT ENGINE PARAMETERS ===
// =========================================================

// --- [1] SAR Betrayal Score ---
// Если SAR перевернулся против сделки — ранний выход
// FIX v2.1: условие сработки >= 2 (не >= SARBetrayalBars),
//           чтобы 1 шумовой бар не блокировал весь сигнал
extern int    SARBetrayalBars         = 3;    // сколько баров проверяем
extern double SARBetrayalMinPips      = 5.0;  // мин. расстояние SAR от цены (фильтр шума)

// --- [2] Momentum Death Signal ---
extern int    MomFastEMA              = 5;
extern int    MomSlowEMA              = 13;
extern int    MomDeathBars            = 4;
extern double MomDeathMinPipsLoss     = 8.0;
extern double MomDeathMaxPipsLoss     = 35.0;

// --- [3] Elastic ATR Trailing Stop ---
// FIX v2.1: трейлинг теперь использует TF самого ордера, не хардкод M15
extern bool   UseElasticTrailing      = true;
extern int    ATR_Period              = 14;
extern double ATR_MultiplierFast      = 1.2;
extern double ATR_MultiplierSlow      = 0.7;
extern int    TrendStrengthBars       = 8;
extern double TrailingActivationPips  = 20.0;

// --- [4] Volatility Pulse Filter ---
// FIX v2.1: порог поднят с 0.0003 до 0.0006 (реалистично для EURUSD M15)
// ATR(14) на M15 EURUSD в норме = 0.0008–0.0020, при 0.0003 ложные срабатывания
extern bool   UseVolatilityPulse      = true;
extern double VolatilityDeadZoneATR   = 0.0006; // ~6 pips для 5-знак. пар — реальный "мертвый" рынок
extern int    VolatilityDeadBarsMin   = 5;

// --- [5] Hard Emergency Exit ---
extern double EmergencyExitPips       = 45.0;

// =========================================================
// GLOBAL VARIABLES
// =========================================================
string PairsList[] = {
   "EURUSD","GBPUSD","AUDUSD","NZDUSD","USDCHF","USDJPY","USDCAD",
   "GBPJPY","EURJPY","CHFJPY","AUDJPY","NZDJPY","GBPAUD","GBPNZD",
   "EURAUD","EURNZD","GBPCAD","GBPCHF","NZDCAD","CADJPY","CADCHF",
   "AUDCAD","AUDCHF","NZDCHF","EURCHF","EURGBP","EURCAD"
};

int TF_Array[] = {60, 30, 15, 5};
datetime LastTradeTime[27][4];

datetime TradingDayStart    = 0;
int      DailyTargetHits    = 0;
bool     TradingLockedForDay = false;
double   CircleStartEquity  = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   ArrayInitialize(LastTradeTime, 0);
   TradingDayStart     = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   DailyTargetHits     = 0;
   TradingLockedForDay = false;
   CircleStartEquity   = AccountBalance();
   Print("KEYLEVEL_TRADER_New1 v2.1 Initialized. SmartExit Engine ACTIVE. CircleEquity: ", CircleStartEquity);
   return(INIT_SUCCEEDED);
}
void OnDeinit(const int reason) {}

//+------------------------------------------------------------------+
void ResetDailyCycleStateIfNeeded()
{
   datetime todayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(TradingDayStart != todayStart) {
      TradingDayStart     = todayStart;
      DailyTargetHits     = 0;
      TradingLockedForDay = false;
      CircleStartEquity   = AccountBalance();
      Print("New trading day. Reset. CircleStartEquity: ", CircleStartEquity);
   }
}

//+------------------------------------------------------------------+
bool CheckAndExecuteDailyTarget()
{
   if(!UseDailyEquityTarget) return false;
   if(TradingLockedForDay) return true;
   if(CircleStartEquity <= 0) return false;

   double targetEquity  = CircleStartEquity * (1.0 + (DailyProfitTargetPercent / 100.0));
   double currentEquity = AccountEquity();

   if(currentEquity >= targetEquity) {
      Print("!!! CIRCLE TARGET REACHED !!! Equity: ", currentEquity, " >= ", targetEquity);
      CloseAllOpenTrades();
      DailyTargetHits++;

      if(DailyTargetHits >= MaxCountCircles) {
         TradingLockedForDay = true;
         Print("Trading locked until next day.");
      } else {
         CircleStartEquity = AccountBalance();
         Print("New circle. Base: ", CircleStartEquity);
      }
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void CloseAllOpenTrades()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;

      for(int attempt = 1; attempt <= 3; attempt++) {
         RefreshRates();
         double closePrice = (OrderType() == OP_BUY)
            ? MarketInfo(OrderSymbol(), MODE_BID)
            : MarketInfo(OrderSymbol(), MODE_ASK);

         if(OrderClose(OrderTicket(), OrderLots(), closePrice, Slippage, clrGreen)) break;

         int err = GetLastError();
         if(err == ERR_OFF_QUOTES || err == ERR_REQUOTE || err == ERR_PRICE_CHANGED) Sleep(500);
         else break;
      }
   }
}

bool CloseOrderByTicket(int ticket, string reason)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES)) return false;

   for(int attempt = 1; attempt <= 3; attempt++) {
      RefreshRates();
      double closePrice = (OrderType() == OP_BUY)
         ? MarketInfo(OrderSymbol(), MODE_BID)
         : MarketInfo(OrderSymbol(), MODE_ASK);

      if(OrderClose(ticket, OrderLots(), closePrice, Slippage, clrOrange)) {
         Print("SmartExit [", reason, "] closed ticket ", ticket,
               " Pair: ", OrderSymbol(),
               " P&L pips: ", DoubleToString(
                  (OrderType() == OP_BUY ?
                     (MarketInfo(OrderSymbol(), MODE_BID) - OrderOpenPrice()) :
                     (OrderOpenPrice() - MarketInfo(OrderSymbol(), MODE_ASK))
                  ) / (
                     (MarketInfo(OrderSymbol(), MODE_DIGITS) == 3 || MarketInfo(OrderSymbol(), MODE_DIGITS) == 5)
                        ? MarketInfo(OrderSymbol(), MODE_POINT) * 10
                        : MarketInfo(OrderSymbol(), MODE_POINT)
                  ), 1));
         return true;
      }
      int err = GetLastError();
      if(err == ERR_OFF_QUOTES || err == ERR_REQUOTE || err == ERR_PRICE_CHANGED) Sleep(300);
      else break;
   }
   return false;
}

// =========================================================
// Извлечь TF из комментария ордера формата "KLN_TF_TYPE"
// Возвращает PERIOD_M15 если парсинг не удался (safe fallback)
// =========================================================
int GetOrderTF(string comment)
{
   // формат: KLN_60_0 или KLN_15_1
   int pos1 = StringFind(comment, "_");
   int pos2 = StringFind(comment, "_", pos1 + 1);
   if(pos1 < 0 || pos2 < 0) return PERIOD_M15;

   int tf = (int)StringToInteger(StringSubstr(comment, pos1 + 1, pos2 - pos1 - 1));
   if(tf == 5)  return PERIOD_M5;
   if(tf == 15) return PERIOD_M15;
   if(tf == 30) return PERIOD_M30;
   if(tf == 60) return PERIOD_H1;
   return PERIOD_M15; // fallback
}

//+------------------------------------------------------------------+
//| TIER LOGIC                                                       |
//+------------------------------------------------------------------+
bool IsTimeframeAllowed(string pair, int tf)
{
   string tier1[] = {"EURUSD","GBPUSD","AUDUSD","NZDUSD","USDCHF","USDJPY","USDCAD","EURJPY"};
   string tier2[] = {"GBPJPY","CHFJPY","AUDJPY","NZDJPY","GBPAUD","GBPNZD","EURAUD","EURNZD","GBPCAD","GBPCHF",
                     "NZDCAD","CADJPY","CADCHF","AUDCAD","AUDCHF","NZDCHF","EURCHF","EURGBP","EURCAD"};

   for(int i=0; i<ArraySize(tier1); i++) if(pair == tier1[i]) return (tf == 60 || tf == 30 || tf == 15 || tf == 5);
   for(int i=0; i<ArraySize(tier2); i++) if(pair == tier2[i]) return (tf == 60 || tf == 30 || tf == 15);
   return (tf == 60 || tf == 30);
}

//+------------------------------------------------------------------+
//| 45-BAR SCAN                                                      |
//+------------------------------------------------------------------+
bool Check45BarScan(string pair, int tf, bool isBuy)
{
   double minHigh = 999999, maxLow = 0;
   double minSAR  = 999999, maxSAR = 0;

   for(int i = 1; i <= 45; i++) {
      double high = iHigh(pair, tf, i);
      double low  = iLow(pair, tf, i);
      double sar  = iSAR(pair, tf, 0.002, 0.2, i);

      if(high < minHigh) minHigh = high;
      if(low  > maxLow)  maxLow  = low;
      if(sar  < minSAR)  minSAR  = sar;
      if(sar  > maxSAR)  maxSAR  = sar;
   }

   if(isBuy) return (minHigh < maxSAR) && (minSAR < maxLow);
   return (maxLow > minSAR) && (maxSAR > minHigh);
}

//+------------------------------------------------------------------+
//| TRIGGER LOGIC                                                    |
//+------------------------------------------------------------------+
bool CheckTrigger(string pair, int tf, bool isBuy)
{
   double green0 = iSAR(pair, tf, 0.002, 0.2, 0);
   double green1 = iSAR(pair, tf, 0.002, 0.2, 1);
   double black0 = iSAR(pair, tf, 0.005, 0.2, 0);
   double black1 = iSAR(pair, tf, 0.005, 0.2, 1);

   double high1 = iHigh(pair, tf, 1);
   double low1  = iLow(pair, tf, 1);
   double high0 = iHigh(pair, tf, 0);
   double low0  = iLow(pair, tf, 0);

   if(isBuy) {
      bool greenRule = (green1 < low1) && (high0 < green0);
      bool blackRule = (black1 < low1) && (high0 < black0);
      return ((greenRule || blackRule) && (high0 < green0));
   } else {
      bool greenRule = (green1 > high1) && (low0 > green0);
      bool blackRule = (black1 > high1) && (low0 > black0);
      return ((greenRule || blackRule) && (low0 > green0));
   }
}

//+------------------------------------------------------------------+
//| TRADE COUNTING                                                   |
//+------------------------------------------------------------------+
int CountTrades(string pair, int tf, int type)
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;
      if(OrderSymbol() != pair) continue;

      string comment = OrderComment();
      int pos1 = StringFind(comment, "_");
      int pos2 = StringFind(comment, "_", pos1 + 1);
      if(pos1 > 0 && pos2 > 0) {
         int orderTf   = (int)StringToInteger(StringSubstr(comment, pos1 + 1, pos2 - pos1 - 1));
         int orderType = (int)StringToInteger(StringSubstr(comment, pos2 + 1));
         if(orderTf == tf && orderType == type && OrderType() == type) count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| MAIN TICK                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyCycleStateIfNeeded();
   if(TradingLockedForDay) return;
   if(CheckAndExecuteDailyTarget()) return;

   SmartExitEngine();

   if(UseElasticTrailing) ElasticATRTrailing();

   for(int p = 0; p < ArraySize(PairsList); p++) {
      string pair = PairsList[p];
      if(MarketInfo(pair, MODE_BID) <= 0) continue;

      for(int i = 0; i < ArraySize(TF_Array); i++) {
         int tf = TF_Array[i];
         if(!IsTimeframeAllowed(pair, tf)) continue;
         if(LastTradeTime[p][i] == iTime(pair, tf, 0)) continue;

         double spreadPips = (MarketInfo(pair, MODE_ASK) - MarketInfo(pair, MODE_BID)) / MarketInfo(pair, MODE_POINT);
         if(MarketInfo(pair, MODE_DIGITS) == 3 || MarketInfo(pair, MODE_DIGITS) == 5) spreadPips /= 10;
         if(spreadPips > MaxSpreadPips) continue;

         bool scanBuy  = Check45BarScan(pair, tf, true);
         bool scanSell = Check45BarScan(pair, tf, false);
         if(!scanBuy && !scanSell) continue;

         bool triggerBuy  = CheckTrigger(pair, tf, true);
         bool triggerSell = CheckTrigger(pair, tf, false);

         if(scanBuy && triggerBuy) {
            int buys  = CountTrades(pair, tf, OP_BUY);
            int sells = CountTrades(pair, tf, OP_SELL);
            if(buys == 0 || (sells > 0 && buys < MaxHedgeOrders))
               ExecuteTrade(pair, tf, OP_BUY, p, i);
         }

         if(scanSell && triggerSell) {
            int buys  = CountTrades(pair, tf, OP_BUY);
            int sells = CountTrades(pair, tf, OP_SELL);
            if(sells == 0 || (buys > 0 && sells < MaxHedgeOrders))
               ExecuteTrade(pair, tf, OP_SELL, p, i);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| EXECUTION                                                        |
//+------------------------------------------------------------------+
void ExecuteTrade(string pair, int tf, int type, int pIndex, int tfIndex)
{
   double pip = (MarketInfo(pair, MODE_DIGITS) == 3 || MarketInfo(pair, MODE_DIGITS) == 5) ?
                MarketInfo(pair, MODE_POINT) * 10 : MarketInfo(pair, MODE_POINT);

   double sl, tp, price, riskDistance;

   if(type == OP_BUY) {
      price        = MarketInfo(pair, MODE_ASK);
      sl           = price - (60 * pip);
      riskDistance = price - sl;
      tp           = price + (180 * pip);
   } else {
      price        = MarketInfo(pair, MODE_BID);
      sl           = price + (60 * pip);
      riskDistance = sl - price;
      tp           = price - (180 * pip);
   }
   if(riskDistance <= 0) return;

   double riskMoney = AccountBalance() * 0.01;
   double tickValue = MarketInfo(pair, MODE_TICKVALUE);
   double tickSize  = MarketInfo(pair, MODE_TICKSIZE);
   double lot = riskMoney / ((riskDistance / tickSize) * tickValue);
   lot = NormalizeDouble(lot, 2);
   lot = MathMax(MarketInfo(pair, MODE_MINLOT), MathMin(MarketInfo(pair, MODE_MAXLOT), lot));

   string comment = StringFormat("KLN_%d_%d", tf, type);
   int ticket = OrderSend(pair, type, lot, price, Slippage, sl, tp, comment, MagicNumber, 0,
                          type == OP_BUY ? clrBlue : clrRed);

   if(ticket > 0) {
      LastTradeTime[pIndex][tfIndex] = iTime(pair, tf, 0);
      Print("Opened ", type == OP_BUY ? "BUY" : "SELL", " | ", pair, " TF:", tf, " Lot:", lot);
   }
}

// =========================================================
// *** SMART EXIT ENGINE ***
// =========================================================
void SmartExitEngine()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;

      string pair   = OrderSymbol();
      int    type   = OrderType();
      int    ticket = OrderTicket();
      double entry  = OrderOpenPrice();

      double pip = (MarketInfo(pair, MODE_DIGITS) == 3 || MarketInfo(pair, MODE_DIGITS) == 5) ?
                   MarketInfo(pair, MODE_POINT) * 10 : MarketInfo(pair, MODE_POINT);

      double bid = MarketInfo(pair, MODE_BID);
      double ask = MarketInfo(pair, MODE_ASK);

      double currentPnlPips = (type == OP_BUY) ? (bid - entry) / pip : (entry - ask) / pip;

      // --- [5] Emergency Exit ---
      if(currentPnlPips <= -EmergencyExitPips) {
         CloseOrderByTicket(ticket, "EMERGENCY_" + DoubleToString(currentPnlPips, 1) + "pips");
         continue;
      }

      // --- [4] Volatility Pulse Filter ---
      if(UseVolatilityPulse && currentPnlPips < 0) {
         if(IsMarketDead(pair, PERIOD_M15)) {
            CloseOrderByTicket(ticket, "VOLATILITY_DEAD");
            continue;
         }
      }

      // --- [1] SAR Betrayal Score ---
      if(currentPnlPips <= -MomDeathMinPipsLoss) {
         if(SARBetrayalDetected(pair, PERIOD_M15, type, pip)) {
            CloseOrderByTicket(ticket, "SAR_BETRAYAL");
            continue;
         }
      }

      // --- [2] Momentum Death Signal ---
      if(currentPnlPips <= -MomDeathMinPipsLoss && currentPnlPips > -MomDeathMaxPipsLoss) {
         if(MomentumDying(pair, PERIOD_M15, type)) {
            CloseOrderByTicket(ticket, "MOMENTUM_DEATH");
            continue;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| [1] SAR Betrayal Detector                                        |
//| FIX v2.1: срабатывает при betrayCount >= 2 (не >= SARBetrayalBars)|
//| Один шумовой бар (filtered by MinPips) не блокирует сигнал       |
//+------------------------------------------------------------------+
bool SARBetrayalDetected(string pair, int tf, int orderType, double pip)
{
   int betrayCount = 0;

   for(int bar = 1; bar <= SARBetrayalBars; bar++) {
      double sar  = iSAR(pair, tf, 0.002, 0.2, bar);
      double high = iHigh(pair, tf, bar);
      double low  = iLow(pair, tf, bar);
      double mid  = (high + low) / 2.0;

      double sarDistPips = MathAbs(sar - mid) / pip;
      if(sarDistPips < SARBetrayalMinPips) continue; // шумовой бар — пропускаем

      if(orderType == OP_BUY  && sar > high) betrayCount++;
      if(orderType == OP_SELL && sar < low)  betrayCount++;
   }

   // FIX: достаточно 2 баров "предательства" из SARBetrayalBars проверенных
   return (betrayCount >= 2);
}

//+------------------------------------------------------------------+
//| [2] Momentum Death Signal                                        |
//+------------------------------------------------------------------+
bool MomentumDying(string pair, int tf, int orderType)
{
   int deathCount = 0;

   for(int bar = 1; bar <= MomDeathBars; bar++) {
      double fastEMA_now  = iMA(pair, tf, MomFastEMA, 0, MODE_EMA, PRICE_CLOSE, bar);
      double slowEMA_now  = iMA(pair, tf, MomSlowEMA, 0, MODE_EMA, PRICE_CLOSE, bar);
      double fastEMA_prev = iMA(pair, tf, MomFastEMA, 0, MODE_EMA, PRICE_CLOSE, bar + 1);
      double slowEMA_prev = iMA(pair, tf, MomSlowEMA, 0, MODE_EMA, PRICE_CLOSE, bar + 1);

      double momNow  = fastEMA_now  - slowEMA_now;
      double momPrev = fastEMA_prev - slowEMA_prev;

      if(orderType == OP_BUY  && momNow < momPrev) deathCount++;
      if(orderType == OP_SELL && momNow > momPrev) deathCount++;
   }

   return (deathCount >= MomDeathBars);
}

//+------------------------------------------------------------------+
//| [4] Volatility Pulse                                             |
//+------------------------------------------------------------------+
bool IsMarketDead(string pair, int tf)
{
   int deadCount = 0;

   for(int bar = 1; bar <= VolatilityDeadBarsMin; bar++) {
      double atr = iATR(pair, tf, ATR_Period, bar);
      if(atr < VolatilityDeadZoneATR) deadCount++;
   }

   return (deadCount >= VolatilityDeadBarsMin);
}

// =========================================================
// *** ELASTIC ATR TRAILING STOP ***
// FIX v2.1: использует TF ордера из комментария, не хардкод M15
// H1-ордер получает ATR по H1, M15-ордер — по M15 и т.д.
// =========================================================
void ElasticATRTrailing()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;

      string pair      = OrderSymbol();
      int    type      = OrderType();
      double entry     = OrderOpenPrice();
      double currentSL = OrderStopLoss();
      double currentTP = OrderTakeProfit();

      // FIX: берём TF из комментария ордера
      int    orderTF   = GetOrderTF(OrderComment());

      double pip = (MarketInfo(pair, MODE_DIGITS) == 3 || MarketInfo(pair, MODE_DIGITS) == 5) ?
                   MarketInfo(pair, MODE_POINT) * 10 : MarketInfo(pair, MODE_POINT);

      double bid = MarketInfo(pair, MODE_BID);
      double ask = MarketInfo(pair, MODE_ASK);

      double currentPnlPips = (type == OP_BUY) ? (bid - entry) / pip : (entry - ask) / pip;

      if(currentPnlPips < TrailingActivationPips) continue;

      // ATR и сила тренда по TF самого ордера
      double atrNow = iATR(pair, orderTF, ATR_Period, 1);
      if(atrNow <= 0) continue;

      double trendStrength = GetTrendStrength(pair, orderTF, type);
      double dynamicMult   = ATR_MultiplierSlow + trendStrength * (ATR_MultiplierFast - ATR_MultiplierSlow);
      double trailingDistance = atrNow * dynamicMult;

      if(type == OP_BUY) {
         double newSL = NormalizeDouble(bid - trailingDistance, (int)MarketInfo(pair, MODE_DIGITS));
         if(newSL > currentSL && newSL < bid) {
            if(newSL < entry) newSL = entry;
            OrderModify(OrderTicket(), entry, newSL, currentTP, 0, clrCyan);
         }
      }
      else if(type == OP_SELL) {
         double newSL = NormalizeDouble(ask + trailingDistance, (int)MarketInfo(pair, MODE_DIGITS));
         if((newSL < currentSL || currentSL == 0) && newSL > ask) {
            if(newSL > entry) newSL = entry;
            OrderModify(OrderTicket(), entry, newSL, currentTP, 0, clrCyan);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Оценка силы тренда [0.0 .. 1.0]                                  |
//+------------------------------------------------------------------+
double GetTrendStrength(string pair, int tf, int orderType)
{
   int alignedBars = 0;

   for(int bar = 1; bar <= TrendStrengthBars; bar++) {
      double open  = iOpen(pair, tf, bar);
      double close = iClose(pair, tf, bar);

      if(orderType == OP_BUY  && close > open) alignedBars++;
      if(orderType == OP_SELL && close < open) alignedBars++;
   }

   return (double)alignedBars / (double)TrendStrengthBars;
}

//+------------------------------------------------------------------+
