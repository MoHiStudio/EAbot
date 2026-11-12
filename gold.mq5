//+------------------------------------------------------------------+
//|                                              GoldScalper_XAUUSDm.mq5 |
//|                                  Copyright 2026, Quant Trader    |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Quant Strategy EA"
#property link      "https://www.mql5.com"
#property version   "1.03"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Input Parameters
input group "=== Risk Management ==="
input double    InpLotSize         = 0.01;      // Fixed Lot Size
input double    InpMaxSpreadPoints = 300.0;     // Max Allowed Spread (in Points)
input ulong     InpMagicNumber     = 109921;    // EA Magic Number

input group "=== Indicator Parameters ==="
input int       InpFastEMA         = 9;         // Fast EMA Period
input int       InpSlowEMA         = 21;        // Slow EMA Period
input int       InpRSIPeriod       = 14;        // RSI Period
input int       InpATRPeriod       = 14;        // ATR Period

input group "=== Exit Targets (ATR Multiplier) ==="
input double    InpSLMultiplier    = 1.5;       // Stop Loss = ATR * Multiplier
input double    InpTPMultiplier    = 4.0;       // Take Profit = ATR * Multiplier

//--- Global Variables
int      h_fastEMA, h_slowEMA, h_rsi, h_atr;
datetime lastBarTime;

//+------------------------------------------------------------------+
//| Helper: Normalize and clamp distance to broker minimums          |
//+------------------------------------------------------------------+
double GetValidStopDistance(string symbol, double rawDistancePrice)
{
   double point       = SymbolInfoDouble(symbol, SYMBOL_POINT);
   long   stopsLevel  = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long   freezeLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   // ব্রোকারের কঠোর সর্বনিম্ন পয়েন্ট নির্ধারণ
   long minPoints = MathMax(stopsLevel, freezeLevel);

   // মাইক্রো-স্প্রেড জাম্প বা ফ্ল্যাকচুয়েশনের জন্য অতিরিক্ত ১০ পয়েন্ট বাফার
   double minAllowedDistance = (double)(minPoints + 10) * point;

   // হিসাবকৃত ATR দূরত্ব এবং ব্রোকারের দূরত্বের মধ্যে যেটি বড় সেটি রিটার্ন করবে
   return MathMax(rawDistancePrice, minAllowedDistance);
}

//+------------------------------------------------------------------+
//| Helper: Round price to broker's discrete tick size               |
//+------------------------------------------------------------------+
double RoundToTickSize(double price, string symbol)
{
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0.0)
      return MathRound(price / tickSize) * tickSize;
      
   return NormalizeDouble(price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);

   // Indicators Initialization
   h_fastEMA = iMA(_Symbol, _Period, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   h_slowEMA = iMA(_Symbol, _Period, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   h_rsi     = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
   h_atr     = iATR(_Symbol, _Period, InpATRPeriod);

   if(h_fastEMA == INVALID_HANDLE || h_slowEMA == INVALID_HANDLE || 
      h_rsi == INVALID_HANDLE || h_atr == INVALID_HANDLE)
   {
      Print("[Init Error] Indicators handle create korte pareni. Code: ", GetLastError());
      return(INIT_FAILED);
   }

   lastBarTime = 0;
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(h_fastEMA);
   IndicatorRelease(h_slowEMA);
   IndicatorRelease(h_rsi);
   IndicatorRelease(h_atr);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // ১. প্রতি বারে শুধুমাত্র একবার এক্সিকিউট হবে
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == 0 || currentBarTime == lastBarTime) return;

   // ২. স্প্রেড ফিল্টার চেক
   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(currentSpread > InpMaxSpreadPoints)
   {
      PrintFormat("[Trade Skip] Spread beshi! Current: %d points, Allowed Max: %G points.", currentSpread, InpMaxSpreadPoints);
      return; 
   }

   // ৩. ইন্ডিকেটর বাফার লোড করা (Bar 1 = সদ্য সমাপ্ত বার, Bar 2 = তার আগের বার)
   double fastEMA[], slowEMA[], rsi[], atr[];
   ArraySetAsSeries(fastEMA, true);
   ArraySetAsSeries(slowEMA, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(h_fastEMA, 0, 1, 2, fastEMA) < 2) 
   {
      Print("[Data Error] Fast EMA buffer load hoyni.");
      return;
   }
   if(CopyBuffer(h_slowEMA, 0, 1, 2, slowEMA) < 2) 
   {
      Print("[Data Error] Slow EMA buffer load hoyni.");
      return;
   }
   if(CopyBuffer(h_rsi, 0, 1, 2, rsi) < 2) 
   {
      Print("[Data Error] RSI buffer load hoyni.");
      return;
   }
   if(CopyBuffer(h_atr, 0, 1, 1, atr) < 1) 
   {
      Print("[Data Error] ATR buffer load hoyni.");
      return;
   }

   // ৪. ওপেন পজিশন চেক (একবারে সর্বোচ্চ ১টি ট্রেড)
   int totalOpen = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            totalOpen++;
         }
      }
   }

   if(totalOpen > 0) 
   {
      return; // Already position open ache
   }

   // ৫. ট্রেড শর্তাবলী বিশ্লেষণ (Ongoing Trend + Momentum Re-entry)
   bool isBullishTrend = (fastEMA[0] > slowEMA[0]);
   bool isBearishTrend = (fastEMA[0] < slowEMA[0]);

   // RSI ট্রিগার: ৫০ লেভেল ক্রস/বাউন্স
   bool buyTrigger  = (rsi[1] <= 50.0 && rsi[0] > 50.0);
   bool sellTrigger = (rsi[1] >= 50.0 && rsi[0] < 50.0);

   // ৬. মার্কেট প্রাইস ও ব্রোকার লেভেল ভ্যালিডেশন
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double rawSL = atr[0] * InpSLMultiplier;
   double rawTP = atr[0] * InpTPMultiplier;

   // ব্রোকারের স্টপ লেভেল অনুযায়ী দূরত্ব ক্ল্যাম্প করা
   double safeSLDistance = GetValidStopDistance(_Symbol, rawSL);
   double safeTPDistance = GetValidStopDistance(_Symbol, rawTP);

   // --- BUY SETUP: অনগোয়িং আপট্রেন্ড + RSI 50 ক্রস আপ ---
   if(isBullishTrend && buyTrigger)
   {
      double sl = RoundToTickSize(ask - safeSLDistance, _Symbol);
      double tp = RoundToTickSize(ask + safeTPDistance, _Symbol);
      
      if(trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "GoldScalp_TrendBuy"))
      {
         PrintFormat("[BUY Success] Price: %G | SL: %G | TP: %G | SL Dist: %.1f pts | RSI: %.2f", 
                     ask, sl, tp, (safeSLDistance / _Point), rsi[0]);
         lastBarTime = currentBarTime;
      }
      else
      {
         PrintFormat("[BUY Failed] Error Code: %d (%s) | Broker Min Stop: %d pts", 
                     trade.ResultRetcode(), 
                     trade.ResultRetcodeDescription(),
                     SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL));
      }
   }
   // --- SELL SETUP: অনগোয়িং ডাউনট্রেন্ড + RSI 50 ক্রস ডাউন ---
   else if(isBearishTrend && sellTrigger)
   {
      // শর্ট পজিশন ক্লোজ হয় Ask প্রাইসে, তাই SL এবং TP Ask সাপেক্ষে মেপে হিসাব করা হলো
      double sl = RoundToTickSize(ask + safeSLDistance, _Symbol);
      double tp = RoundToTickSize(bid - safeTPDistance, _Symbol);
      
      if(trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "GoldScalp_TrendSell"))
      {
         PrintFormat("[SELL Success] Price: %G | SL: %G | TP: %G | SL Dist: %.1f pts | RSI: %.2f", 
                     bid, sl, tp, (safeSLDistance / _Point), rsi[0]);
         lastBarTime = currentBarTime;
      }
      else
      {
         PrintFormat("[SELL Failed] Error Code: %d (%s) | Broker Min Stop: %d pts", 
                     trade.ResultRetcode(), 
                     trade.ResultRetcodeDescription(),
                     SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL));
      }
   }
   else
   {
      // শর্ত না মিললে স্ট্যাটাস লগ
      datetime barTime = iTime(_Symbol, _Period, 1);
      PrintFormat("[No Setup] BarTime: %s | Trend: %s | RSI[0]: %.2f (Prev: %.2f) | Trigger - Buy: %s, Sell: %s",
                  TimeToString(barTime, TIME_DATE|TIME_MINUTES),
                  isBullishTrend ? "BULLISH" : (isBearishTrend ? "BEARISH" : "FLAT"),
                  rsi[0], rsi[1],
                  buyTrigger ? "YES" : "NO", sellTrigger ? "YES" : "NO");
      
      lastBarTime = currentBarTime;
   }
}
//+------------------------------------------------------------------+
