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
extern double TrailingActivationPips  = 12.0;  // ниже = раньше защищаем прибыль (заменяет give-back)

// --- [4] Volatility Pulse Filter ---
// FIX v2.1: порог поднят с 0.0003 до 0.0006 (реалистично для EURUSD M15)
// ATR(14) на M15 EURUSD в норме = 0.0008–0.0020, при 0.0003 ложные срабатывания
extern bool   UseVolatilityPulse      = true;
extern double VolatilityDeadZoneATR   = 0.0006; // ~6 pips для 5-знак. пар — реальный "мертвый" рынок
extern int    VolatilityDeadBarsMin   = 5;

// --- [5] Hard Emergency Exit ---
extern double EmergencyExitPips       = 45.0;

// =========================================================
// === [6] ADAPTIVE CONVICTION EXIT (ACE) ===
// Единый балл "рынок за нас" S in [-1..+1] = (SAR + EMA-наклон + сила тренда)/3,
// считается по ТФ ОРДЕРА. Плюс защита пика прибыли (give-back) и частичная фиксация.
// =========================================================
extern double ConvictionExitLoss     = 0.50;  // в минусе: S <= -этого -> выход
extern double ConvictionExitProfit   = 0.70;  // в плюсе: S <= -этого -> банкуем (разворот против)

// --- Геометрия риска (единый источник R, restart-safe) ---
extern double InitialStopPips        = 60.0;  // стартовый стоп
extern double InitialTP_RR           = 3.0;   // тейк = R * этого (180 пипсов при 60)

// --- Частичная фиксация ---
// Состояние "уже порезано" НЕ хранится в памяти: оно читается из позиции стопа
// (для BUY: SL>=entry => безубыток уже выставлен => резать нельзя). Переживает рестарт.
extern bool   UsePartialClose         = true;
extern double PartialAtR              = 1.0;   // на +1R закрыть часть
extern double PartialClosePercent     = 50.0;  // сколько % позиции фиксировать
extern double BreakevenBufferPips     = 2.0;   // буфер безубытка для остатка

// --- Смягчение "единогласия" (majority вместо all) ---
extern int    MomDeathMinCount        = 3;     // из MomDeathBars баров
extern int    VolatilityDeadMinCount  = 3;     // из VolatilityDeadBarsMin баров

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

// Кеш тяжёлого Check45BarScan (зависит только от закрытых баров -> инвариантен внутри бара).
// Пересчитывается раз на новый бар => ~99% нагрузки уходит, логика входа не меняется.
bool     ScanBuyCache[27][4];
bool     ScanSellCache[27][4];
datetime ScanBarTime[27][4];

datetime TradingDayStart    = 0;
int      DailyTargetHits    = 0;
bool     TradingLockedForDay = false;
double   CircleStartEquity  = 0;

// ACE НЕ хранит состояние позиций в памяти: всё восстанавливается из самой позиции
// (OrderOpenPrice / OrderStopLoss), что делает движок устойчивым к перезапуску терминала.

//+------------------------------------------------------------------+
int OnInit()
{
   ArrayInitialize(LastTradeTime, 0);
   ArrayInitialize(ScanBarTime, 0);
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

         // Тяжёлый скан считаем только на новом баре (результат не меняется внутри бара).
         datetime barT = iTime(pair, tf, 0);
         if(ScanBarTime[p][i] != barT) {
            ScanBuyCache[p][i]  = Check45BarScan(pair, tf, true);
            ScanSellCache[p][i] = Check45BarScan(pair, tf, false);
            ScanBarTime[p][i]   = barT;
         }
         bool scanBuy  = ScanBuyCache[p][i];
         bool scanSell = ScanSellCache[p][i];
         if(!scanBuy && !scanSell) continue;

         // Лёгкий триггер (зависит от формирующегося бара) — на каждый тик, как и раньше.
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
      sl           = price - (InitialStopPips * pip);
      riskDistance = price - sl;
      tp           = price + (InitialStopPips * InitialTP_RR * pip);
   } else {
      price        = MarketInfo(pair, MODE_BID);
      sl           = price + (InitialStopPips * pip);
      riskDistance = sl - price;
      tp           = price - (InitialStopPips * InitialTP_RR * pip);
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
// *** ADAPTIVE CONVICTION EXIT (ACE) ENGINE ***  (stateless)
// FIX: все детекторы считаются по ТФ ОРДЕРА (GetOrderTF), не по хардкоду M15.
// Состояние НЕ хранится в памяти — всё читается из позиции (entry/SL), поэтому
// перезапуск терминала ничего не ломает (нет повторной порезки, нет потери фазы).
// Защита прибыли = эластичный ATR-трейлинг (он и есть restart-safe "give-back").
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
      double sl     = OrderStopLoss();
      int    tf     = GetOrderTF(OrderComment());   // <-- ТФ ордера, а не M15

      double pip = PipOf(pair);
      double bid = MarketInfo(pair, MODE_BID);
      double ask = MarketInfo(pair, MODE_ASK);
      double currentPnlPips = (type == OP_BUY) ? (bid - entry) / pip : (entry - ask) / pip;

      // --- [5] Hard Emergency Exit (страховка) ---
      if(currentPnlPips <= -EmergencyExitPips) {
         CloseOrderByTicket(ticket, "EMERGENCY_" + DoubleToString(currentPnlPips, 1) + "pips");
         continue;
      }

      // --- Частичная фиксация на +1R: режем %, остаток -> безубыток ---
      // "Уже порезано" определяется фазой стопа (PartialDone), а не флагом в памяти.
      if(UsePartialClose && !PartialDone(type, entry, sl) &&
         currentPnlPips >= PartialAtR * InitialStopPips) {
         DoPartialAndBE(ticket);
         continue;   // остатком (новый тикет, но SL уже в БУ) займёмся на следующем тике
      }

      if(currentPnlPips > 0) {
         // Жёсткий разворот против прибыли — банкуем. Считаем S лениво и только
         // когда прибыль реально набрана (фейд стартует с S<0, иначе зарежем рано).
         if(currentPnlPips >= TrailingActivationPips) {
            double S = ConvictionScore(pair, tf, type);
            if(S <= -ConvictionExitProfit) {
               CloseOrderByTicket(ticket, "CONV_FLIP_PROFIT_" + DoubleToString(S,2));
               continue;
            }
         }
      }
      else {
         // --- [4] Мёртвый рынок (по ТФ ордера) ---
         if(UseVolatilityPulse && IsMarketDead(pair, tf)) {
            CloseOrderByTicket(ticket, "VOLATILITY_DEAD");
            continue;
         }
         // дальше — только в коридоре потерь
         if(currentPnlPips <= -MomDeathMinPipsLoss) {
            // --- [1] SAR Betrayal (по ТФ ордера) ---
            if(SARBetrayalDetected(pair, tf, type, pip)) {
               CloseOrderByTicket(ticket, "SAR_BETRAYAL");
               continue;
            }
            // --- Убеждённость уверенно против нас (S считаем лениво) ---
            double S = ConvictionScore(pair, tf, type);
            if(S <= -ConvictionExitLoss) {
               CloseOrderByTicket(ticket, "CONV_AGAINST_" + DoubleToString(S,2));
               continue;
            }
            // --- [2] Momentum Death (по ТФ ордера, в коридоре потерь) ---
            if(currentPnlPips > -MomDeathMaxPipsLoss && MomentumDying(pair, tf, type)) {
               CloseOrderByTicket(ticket, "MOMENTUM_DEATH");
               continue;
            }
         }
      }
   }
}

// =========================================================
// ACE: фаза "частичка уже сделана / безубыток выставлен" — читается из SL.
// BUY: SL>=entry, SELL: SL<=entry. Без частички трейлинг ведёт сразу к БУ.
// =========================================================
bool PartialDone(int type, double entry, double sl)
{
   if(!UsePartialClose) return true;
   if(sl == 0) return false;
   return (type == OP_BUY) ? (sl >= entry) : (sl <= entry);
}

// =========================================================
// ACE: единый балл убеждённости S in [-1..+1]
//   (позиция SAR + наклон EMA-моментума + доля согласованных баров) / 3
// >0 = рынок за нас, <0 = против. Считается по ТФ ордера.
// =========================================================
double ConvictionScore(string pair, int tf, int type)
{
   double price = iClose(pair, tf, 1);

   double sar  = iSAR(pair, tf, 0.002, 0.2, 1);
   double sSAR = (type == OP_BUY) ? ((sar < price) ? 1.0 : -1.0)
                                  : ((sar > price) ? 1.0 : -1.0);

   double mNow  = iMA(pair, tf, MomFastEMA, 0, MODE_EMA, PRICE_CLOSE, 1) -
                  iMA(pair, tf, MomSlowEMA, 0, MODE_EMA, PRICE_CLOSE, 1);
   double mPrev = iMA(pair, tf, MomFastEMA, 0, MODE_EMA, PRICE_CLOSE, 2) -
                  iMA(pair, tf, MomSlowEMA, 0, MODE_EMA, PRICE_CLOSE, 2);
   double slope = mNow - mPrev;
   double sMom  = (type == OP_BUY) ? ((slope > 0) ? 1.0 : -1.0)
                                   : ((slope < 0) ? 1.0 : -1.0);

   double sTrend = GetTrendStrength(pair, tf, type) * 2.0 - 1.0;  // [0..1] -> [-1..1]

   return (sSAR + sMom + sTrend) / 3.0;
}

// =========================================================
// ACE: частичная фиксация + перевод остатка в безубыток.
// Сначала двигаем SL в БУ (никогда не ослабляя текущий), затем режем часть —
// остаток MT4 откроет новым тикетом, но с уже подтянутым SL.
// =========================================================
void DoPartialAndBE(int ticket)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES)) return;

   string pair  = OrderSymbol();
   int    type  = OrderType();
   double entry = OrderOpenPrice();
   double lots  = OrderLots();
   double tp    = OrderTakeProfit();
   double curSL = OrderStopLoss();
   int    digits = (int)MarketInfo(pair, MODE_DIGITS);
   double pip   = PipOf(pair);
   double buf   = BreakevenBufferPips * pip;

   double newSL;
   if(type == OP_BUY) {
      newSL = MathMax(curSL, entry + buf);
      newSL = NormalizeDouble(newSL, digits);
      if(newSL > curSL) OrderModify(ticket, entry, newSL, tp, 0, clrAqua);
   } else {
      double be = entry - buf;
      newSL = (curSL == 0) ? be : MathMin(curSL, be);
      newSL = NormalizeDouble(newSL, digits);
      if(curSL == 0 || newSL < curSL) OrderModify(ticket, entry, newSL, tp, 0, clrAqua);
   }

   double lotStep = MarketInfo(pair, MODE_LOTSTEP);
   double minLot  = MarketInfo(pair, MODE_MINLOT);
   if(lotStep <= 0) lotStep = 0.01;

   double closeLots = MathFloor((lots * (PartialClosePercent / 100.0)) / lotStep) * lotStep;
   closeLots = NormalizeDouble(closeLots, 2);
   if(closeLots < minLot)            return;   // слишком мелко, чтобы резать
   if(lots - closeLots < minLot)     return;   // остаток был бы меньше мин. лота

   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES)) return;
   RefreshRates();
   double price = (type == OP_BUY) ? MarketInfo(pair, MODE_BID) : MarketInfo(pair, MODE_ASK);
   OrderClose(ticket, closeLots, price, Slippage, clrViolet);
}

// =========================================================
// ACE: pip-размер
// =========================================================
double PipOf(string pair)
{
   int d = (int)MarketInfo(pair, MODE_DIGITS);
   return (d == 3 || d == 5) ? MarketInfo(pair, MODE_POINT) * 10 : MarketInfo(pair, MODE_POINT);
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

   // majority вместо all: достаточно большинства "умирающих" баров
   int need = MathMin(MomDeathMinCount, MomDeathBars);
   return (deathCount >= need);
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

   // majority вместо all: рынок "мёртв", если большинство баров без волатильности
   int need = MathMin(VolatilityDeadMinCount, VolatilityDeadBarsMin);
   return (deadCount >= need);
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

      // До частичной фиксации стоп нельзя доводить до безубытка — иначе он "съест"
      // фазу частички (PartialDone читается из SL). Поэтому поджимаем, упираясь в entry-eps.
      bool   beforePartial = (UsePartialClose && !PartialDone(type, entry, currentSL));
      double eps = pip;  // 1 пипс зазора, чтобы фаза оставалась "не сделана"

      if(type == OP_BUY) {
         double newSL = bid - trailingDistance;
         if(beforePartial) newSL = MathMin(newSL, entry - eps);   // не достигаем БУ раньше частички
         else              newSL = MathMax(newSL, entry);          // после частички — не ниже БУ
         newSL = NormalizeDouble(newSL, (int)MarketInfo(pair, MODE_DIGITS));
         if(newSL > currentSL && newSL < bid)
            OrderModify(OrderTicket(), entry, newSL, currentTP, 0, clrCyan);
      }
      else if(type == OP_SELL) {
         double newSL = ask + trailingDistance;
         if(beforePartial) newSL = MathMax(newSL, entry + eps);
         else              newSL = MathMin(newSL, entry);
         newSL = NormalizeDouble(newSL, (int)MarketInfo(pair, MODE_DIGITS));
         if((newSL < currentSL || currentSL == 0) && newSL > ask)
            OrderModify(OrderTicket(), entry, newSL, currentTP, 0, clrCyan);
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
