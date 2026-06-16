//+------------------------------------------------------------------+
//| HarmonicSAR_EA.mq4 |
//| Multi-Timeframe Harmonic Parabolic SAR EA |
//+------------------------------------------------------------------+
#property copyright "Harmonic SAR Strategy"
#property link ""
#property version "6.00"
#property strict
// --- INPUT PARAMETERS ---
extern bool UsePercentRisk = true;
extern double RiskPercent = 1.0;
extern double FixedLotSize = 0.1;
extern bool UseSpreadFilter = true;
extern double MaxSpreadPct = 0.20;
extern bool UseTimeframePairing = true;
extern int MaxTradesPerPair = 1;    // Max open trades per symbol (any direction)
extern int StartHour = 3;           // Trading start hour, broker/server time
extern int EndHour = 23;            // Trading end hour, broker/server time
extern int MagicNumber = 20240606;
extern int Slippage = 3;
extern double EqualPriceTolerance = 3.0; // Tolerance for cross-TF price equality
// --- GLOBAL VARIABLES ---
string PairsList[] =
  {
   "EURUSD","GBPUSD","AUDUSD","NZDUSD","USDCHF","USDJPY","USDCAD",
   "GBPJPY","EURJPY","CHFJPY","AUDJPY","NZDJPY","GBPAUD","GBPNZD",
   "EURAUD","EURNZD","GBPCAD","GBPCHF","NZDCAD","CADJPY","CADCHF",
   "AUDCAD","AUDCHF","NZDCHF","EURCHF","EURGBP"
  };
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int TF_Array[] = {5, 15, 30, 60}; // M5, M15, M30, H1 (signals)
int HigherTF_Array[] = {15, 30, 60, 240}; // M15, M30, H1, H4 (confirmation)
datetime LastTradeTime[27][4];
//+------------------------------------------------------------------+
int OnInit()
  {
   ArrayInitialize(LastTradeTime, 0);
   Print("Harmonic SAR EA Initialized. Scanning for Cross-TF Alignment.");
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {}
//+------------------------------------------------------------------+
int CountOpenTradesForPair(string pair)
  {
   int count = 0;
   for(int i = 0; i < OrdersTotal(); i++)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() != MagicNumber)
         continue;
      if(OrderSymbol() != pair)
         continue;
      count++;
     }
   return count;
  }
//+------------------------------------------------------------------+
bool IsTradingHour()
  {
   int hour = TimeHour(TimeCurrent());

   if(StartHour < 0 || StartHour > 23 || EndHour < 0 || EndHour > 23)
      return true;

   if(StartHour == EndHour)
      return true;

   if(StartHour < EndHour)
      return (hour >= StartHour && hour <= EndHour);

   return (hour >= StartHour || hour <= EndHour);
  }
//+------------------------------------------------------------------+
void OnTick()
  {
   ManageOpenTrades();

   if(!IsTradingHour())
      return;

   for(int p = 0; p < ArraySize(PairsList); p++)
     {
      string pair = PairsList[p];
      if(MarketInfo(pair, MODE_BID) <= 0)
         continue;
      if(CountOpenTradesForPair(pair) >= MaxTradesPerPair)
         continue;
      for(int i = 0; i < ArraySize(TF_Array); i++)
        {
         int tf = TF_Array[i];
         int htf = HigherTF_Array[i];
         if(UseTimeframePairing && !IsTimeframeAllowed(pair, tf))
            continue;
         if(LastTradeTime[p][i] == iTime(pair, tf, 0))
            continue;
         // --- Get SAR Values for Current TF ---
         double black_tf = iSAR(pair, tf, 0.005, 0.2, 0);
         double blue_tf = iSAR(pair, tf, 0.01, 0.2, 0);
         // --- Get SAR Values for Higher TF ---
         double black_htf = iSAR(pair, htf, 0.005, 0.2, 0);
         double blue_htf = iSAR(pair, htf, 0.01, 0.2, 0);
         double bid = MarketInfo(pair, MODE_BID);
         double ask = MarketInfo(pair, MODE_ASK);
         double point = MarketInfo(pair, MODE_POINT);
         int digits = (int)MarketInfo(pair, MODE_DIGITS);
         // --- BUY SIGNALS ---
         // 1. Black & Blue below price on BOTH timeframes
         bool belowPrice_tf = (black_tf < bid) && (blue_tf < bid);
         bool belowPrice_htf = (black_htf < bid) && (blue_htf < bid);
         // 2. Black & Blue at equal price on Current TF
         bool equalLevel_tf = (MathAbs(black_tf - blue_tf) <= (EqualPriceTolerance * point));
         // 3. Black & Blue at equal price on Higher TF
         bool equalLevel_htf = (MathAbs(black_htf - blue_htf) <= (EqualPriceTolerance * point));
         // 4. Cross-TF Alignment: Both TFs at SAME price level
         bool crossTF_Align = (MathAbs(black_tf - black_htf) <= (EqualPriceTolerance * point))
                              &&
                              (MathAbs(blue_tf - blue_htf) <= (EqualPriceTolerance * point));
         if(belowPrice_tf && belowPrice_htf && equalLevel_tf && equalLevel_htf &&
            crossTF_Align)
           {
            if(CountOpenTradesForPair(pair) >= MaxTradesPerPair)
               break;
            double slLevel = MathMin(black_tf, blue_tf);
            ExecuteBuy(pair, "HarmonicBuy", slLevel, tf, htf, p, i, point, digits);
           }
         // --- SELL SIGNALS ---
         // 1. Black & Blue above price on BOTH timeframes
         bool abovePrice_tf = (black_tf > ask) && (blue_tf > ask);
         bool abovePrice_htf = (black_htf > ask) && (blue_htf > ask);
         // 2. Black & Blue at equal price on Current TF
         bool equalLevelSell_tf = (MathAbs(black_tf - blue_tf) <= (EqualPriceTolerance * point));
         // 3. Black & Blue at equal price on Higher TF
         bool equalLevelSell_htf = (MathAbs(black_htf - blue_htf) <= (EqualPriceTolerance *
                                    point));
         // 4. Cross-TF Alignment: Both TFs at SAME price level
         bool crossTF_AlignSell = (MathAbs(black_tf - black_htf) <= (EqualPriceTolerance *
                                   point)) &&
                                  (MathAbs(blue_tf - blue_htf) <= (EqualPriceTolerance * point));
         if(abovePrice_tf && abovePrice_htf && equalLevelSell_tf && equalLevelSell_htf &&
            crossTF_AlignSell)
           {
            if(CountOpenTradesForPair(pair) >= MaxTradesPerPair)
               break;
            double slLevel = MathMax(black_tf, blue_tf);
            ExecuteSell(pair, "HarmonicSell", slLevel, tf, htf, p, i, point, digits);
           }
        }
     }
  }
//+------------------------------------------------------------------+
void ExecuteBuy(string pair, string signalType, double slLevel, int tf, int htf, int pIndex, int
                tfIndex, double point, int digits)
  {
   double sl = NormalizeDouble(slLevel - (point * 5), digits);
   double ask = MarketInfo(pair, MODE_ASK);
   double riskDistance = ask - sl;
   if(riskDistance <= 0)
      return;
   double tp = NormalizeDouble(ask + (riskDistance * 3.0), digits);
   if(UseSpreadFilter)
     {
      double spread = MarketInfo(pair, MODE_SPREAD) * point;
      if(spread > (MaxSpreadPct * riskDistance))
         return;
     }
   double lotSize = GetLotSize(pair, riskDistance);
   string comment = StringFormat("%s_%d_%d", signalType, tf, htf);
   int ticket = OrderSend(pair, OP_BUY, lotSize, ask, Slippage, sl, tp, comment, MagicNumber, 0,
                          clrBlue);
   if(ticket > 0)
     {
      LastTradeTime[pIndex][tfIndex] = iTime(pair, tf, 0);
      Print("BUY Harmonic opened on ", pair, " ", TimeframeToString(tf), " confirmed by ",
            TimeframeToString(htf));
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ExecuteSell(string pair, string signalType, double slLevel, int tf, int htf, int pIndex, int
                 tfIndex, double point, int digits)
  {
   double sl = NormalizeDouble(slLevel + (point * 5), digits);
   double bid = MarketInfo(pair, MODE_BID);
   double riskDistance = sl - bid;
   if(riskDistance <= 0)
      return;
   double tp = NormalizeDouble(bid - (riskDistance * 3.0), digits);
   if(UseSpreadFilter)
     {
      double spread = MarketInfo(pair, MODE_SPREAD) * point;
      if(spread > (MaxSpreadPct * riskDistance))
         return;
     }
   double lotSize = GetLotSize(pair, riskDistance);
   string comment = StringFormat("%s_%d_%d", signalType, tf, htf);
   int ticket = OrderSend(pair, OP_SELL, lotSize, bid, Slippage, sl, tp, comment, MagicNumber,
                          0, clrRed);
   if(ticket > 0)
     {
      LastTradeTime[pIndex][tfIndex] = iTime(pair, tf, 0);
      Print("SELL Harmonic opened on ", pair, " ", TimeframeToString(tf), " confirmed by ",
            TimeframeToString(htf));
     }
  }
//+------------------------------------------------------------------+
void ManageOpenTrades()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() != MagicNumber)
         continue;
      string pair = OrderSymbol();
      string comment = OrderComment();
      int pos = StringFind(comment, "_");
      if(pos == -1)
         continue;
      // Extract TF and HTF from comment
      string parts[];
      StringSplit(comment, '_', parts);
      if(ArraySize(parts) < 3)
         continue;
      int tf = (int)StringToInteger(parts[1]);
      int htf = (int)StringToInteger(parts[2]);
      double bid = MarketInfo(pair, MODE_BID);
      double ask = MarketInfo(pair, MODE_ASK);
      // Get Black SAR for both timeframes
      double black_tf = iSAR(pair, tf, 0.005, 0.2, 0);
      double black_htf = iSAR(pair, htf, 0.005, 0.2, 0);
      if(OrderType() == OP_BUY)
        {
         double openPrice = OrderOpenPrice();
         bool inProfit = (bid > openPrice);
         // EXIT RULE: If in profit and current TF Black SAR flips, exit
         if(inProfit && black_tf > ask)
           {
            CloseOrder(OrderTicket(), pair);
            Print("BUY closed on profit by ", TimeframeToString(tf), " flip");
           }
         // EXIT RULE: If not in profit (or TF didn't flip), wait for HTF Black SAR flip
         else
            if(black_htf > ask)
              {
               CloseOrder(OrderTicket(), pair);
               Print("BUY closed by ", TimeframeToString(htf), " flip");
              }
        }
      else
         if(OrderType() == OP_SELL)
           {
            double openPrice = OrderOpenPrice();
            bool inProfit = (ask < openPrice);
            // EXIT RULE: If in profit and current TF Black SAR flips, exit
            if(inProfit && black_tf < bid)
              {
               CloseOrder(OrderTicket(), pair);
               Print("SELL closed on profit by ", TimeframeToString(tf), " flip");
              }
            // EXIT RULE: If not in profit (or TF didn't flip), wait for HTF Black SAR flip
            else
               if(black_htf < bid)
                 {
                  CloseOrder(OrderTicket(), pair);
                  Print("SELL closed by ", TimeframeToString(htf), " flip");
                 }
           }
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CloseOrder(int ticket, string pair)
  {
   OrderSelect(ticket, SELECT_BY_TICKET);
   if(OrderType() == OP_BUY)
      OrderClose(ticket, OrderLots(), MarketInfo(pair, MODE_BID), Slippage, CLR_NONE);
   else
      OrderClose(ticket, OrderLots(), MarketInfo(pair, MODE_ASK), Slippage, CLR_NONE);
  }
//+------------------------------------------------------------------+
double GetLotSize(string pair, double slDistance)
  {
   if(!UsePercentRisk)
      return FixedLotSize;
   double riskMoney = AccountBalance() * (RiskPercent / 100.0);
   double tickValue = MarketInfo(pair, MODE_TICKVALUE);
   double tickSize = MarketInfo(pair, MODE_TICKSIZE);
   if(tickValue == 0 || tickSize == 0)
      return FixedLotSize;
   double slPoints = slDistance / tickSize;
   double lot = riskMoney / (slPoints * tickValue);
   double minLot = MarketInfo(pair, MODE_MINLOT);
   double maxLot = MarketInfo(pair, MODE_MAXLOT);
   double lotStep = MarketInfo(pair, MODE_LOTSTEP);
   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return NormalizeDouble(lot, 2);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsTimeframeAllowed(string pair, int tf)
  {
   string tier1[] =
     {"EURUSD","GBPUSD","AUDUSD","NZDUSD","USDCHF","USDJPY","USDCAD"};
   string tier2[] =
     {
      "GBPJPY","EURJPY","CHFJPY","AUDJPY","NZDJPY","GBPAUD","GBPNZD","EURAUD",
      "EURNZD","GBPCAD","GBPCHF"
     };
   string tier3[] =
     {"NZDCAD","CADJPY","CADCHF","AUDCAD","AUDCHF","NZDCHF","EURCHF","EURGBP"};
   for(int i=0; i<ArraySize(tier1); i++)
      if(pair == tier1[i])
         return true;
   for(int j=0; j<ArraySize(tier2); j++)
      if(pair == tier2[j])
         return (tf >= 60);
   for(int k=0; k<ArraySize(tier3); k++)
      if(pair == tier3[k])
         return (tf >= 240);
   return true;
  }
//+------------------------------------------------------------------+
string TimeframeToString(int tf)
  {
   if(tf==5)
      return "M5";
   if(tf==15)
      return "M15";
   if(tf==30)
      return "M30";
   if(tf==60)
      return "H1";
   if(tf==240)
      return "H4";
   return "Unknown";
  }
//+------------------------------------------------------------------+
