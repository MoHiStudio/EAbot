//+------------------------------------------------------------------+
//|                                                         gold.mq5 |
//|                                  Copyright 2026, Quant Trader    |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Quant Strategy EA"
#property link      "https://www.mql5.com"
#property version   "1.05"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Input Parameters
input group "=== Risk Management ==="
input double    InpLotSize         = 0.01;      // Fixed Lot Size
input double    InpMaxSpreadPoints = 300.0;     // Max Allowed Spread (in Points)
input ulong     InpMagicNumber     = 109921;    // EA Magic Number

input group "=== Breakeven Settings ==="
input bool      InpUseBreakeven    = true;      // Enable Breakeven Function
input double    InpBETriggerATR    = 1.0;       // Trigger: Profit >= ATR * Multiplier
input double    InpBELockPoints    = 20.0;      // Profit Locked Above/Below Open (Points)

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

   long minPoints = MathMax(stopsLevel, freezeLevel);
   double minAllowedDistance = (double)(minPoints + 10) * point;

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
//| Check and apply Breakeven Stop Loss to open positions             |
//+------------------------------------------------------------------+
void ApplyBreakeven()
{
   if(!InpUseBreakeven) return;

   double atrVal[];
   ArraySetAsSeries(atrVal, true);
   if(CopyBuffer(h_atr, 0, 1, 1, atrVal) < 1) return;

   double triggerDist = atrVal[0] * InpBETriggerATR;
   double point       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double lockOffset  = InpBELockPoints * point;

   double currentBid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol || 
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      long   posType  = PositionGetInteger(POSITION_TYPE);
      double openPrice= PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL= PositionGetDouble(POSITION_SL);
      double currentTP= PositionGetDouble(POSITION_TP);

      // Buy Position Check
      if(posType == POSITION_TYPE_BUY)
      {
         if((currentBid - openPrice) >= triggerDist)
         {
            double newSL = RoundToTickSize(openPrice + lockOffset, _Symbol);

            if(newSL > currentSL + (point * 2.0))
            {
               if(GetValidStopDistance(_Symbol, currentBid - newSL) <= (currentBid - newSL))
               {
                  if(trade.PositionModify(ticket, newSL, currentTP))
                  {
                     PrintFormat("[Breakeven Applied] BUY Ticket #%I64u -> New SL: %G (+%.1f pts)", 
                                 ticket, newSL, InpBELockPoints);
                  }
               }
            }
         }
      }
      // Sell Position Check
      else if(posType == POSITION_TYPE_SELL)
      {
         if((openPrice - currentAsk) >= triggerDist)
         {
            double newSL = RoundToTickSize(openPrice - lockOffset, _Symbol);

            if(currentSL == 0.0 || newSL < currentSL - (point * 2.0))
            {
               if(GetValidStopDistance(_Symbol, newSL - currentAsk) <= (newSL - currentAsk))
               {
                  if(trade.PositionModify(ticket, newSL, currentTP))
                  {
                     PrintFormat("[Breakeven Applied] SELL Ticket #%I64u -> New SL: %G (+%.1f pts)", 
                                 ticket, newSL, InpBELockPoints);
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Real-time Breakeven trailing check (Runs on every tick)
   ApplyBreakeven();

   // 2. Bar completion lock (New trades execute only on closed bars)
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == 0 || currentBarTime == lastBarTime) return;

   // 3. Spread Filter Check
   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(currentSpread > InpMaxSpreadPoints)
   {
      PrintFormat("[Trade Skip] Spread beshi! Current: %d points, Allowed Max: %G points.", currentSpread, InpMaxSpreadPoints);
      return; 
   }

   // 4. Indicator Buffers
   double fastEMA[], slowEMA[], rsi[], atr[];
   ArraySetAsSeries(fastEMA, true);
   ArraySetAsSeries(slowEMA, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(h_fastEMA, 0, 1, 2, fastEMA) < 2) return;
   if(CopyBuffer(h_slowEMA, 0, 1, 2, slowEMA) < 2) return;
   if(CopyBuffer(h_rsi, 0, 1, 2, rsi) < 2) return;
   if(CopyBuffer(h_atr, 0, 1, 1, atr) < 1) return;

   // 5. Open Positions Filter (1 trade max)
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

   if(totalOpen > 0) return;

   // 6. Ongoing Trend & Momentum Trigger
   bool isBullishTrend = (fastEMA[0] > slowEMA[0]);
   bool isBearishTrend = (fastEMA[0] < slowEMA[0]);

   bool buyTrigger  = (rsi[1] <= 50.0 && rsi[0] > 50.0);
   bool sellTrigger = (rsi[1] >= 50.0 && rsi[0] < 50.0);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double rawSL = atr[0] * InpSLMultiplier;
   double rawTP = atr[0] * InpTPMultiplier;

   double safeSLDistance = GetValidStopDistance(_Symbol, rawSL);
   double safeTPDistance = GetValidStopDistance(_Symbol, rawTP);

   // --- BUY SETUP ---
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
         PrintFormat("[BUY Failed] Error: %d (%s) | Broker Min Stop: %d pts", 
                     trade.ResultRetcode(), trade.ResultRetcodeDescription(),
                     SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL));
      }
   }
   // --- SELL SETUP ---
   else if(isBearishTrend && sellTrigger)
   {
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
         PrintFormat("[SELL Failed] Error: %d (%s) | Broker Min Stop: %d pts", 
                     trade.ResultRetcode(), trade.ResultRetcodeDescription(),
                     SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL));
      }
   }
   else
   {
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
