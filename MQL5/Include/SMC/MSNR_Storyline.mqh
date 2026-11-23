//+------------------------------------------------------------------+
//|  MSNR_Storyline.mqh                                              |
//|  OPTIONAL module (A7), active only when InpEnableMSNR = true.     |
//|                                                                  |
//|  A storyline = rejection of a key level on a larger TF and a      |
//|  BODY-close breakout one timeframe lower:                         |
//|    D1 level rejected -> H4 break                                  |
//|    W1 level rejected -> D1 break                                  |
//|    MN1 level rejected -> W1 break                                 |
//|  TFs below daily are never used. Targets/obstacles are ordered    |
//|  key levels; last-liquidity uses the 4.x liquidity helpers.       |
//+------------------------------------------------------------------+
#ifndef MSNR_STORYLINE_MQH
#define MSNR_STORYLINE_MQH

#include "SMC_Types.mqh"
#include "SMC_Structure.mqh"
#include "MSNR_Levels.mqh"

struct MSNR_Story
{
   bool              confirmed;
   int               dir;
   ENUM_TIMEFRAMES   rejectTF;
   ENUM_TIMEFRAMES   breakTF;
   double            breakoutLevel;
   double            targets[3];
   int               targetCount;
   double            obstacles[8];
   int               obstacleCount;
   bool              lastLiquidityTaken;
};

class CMSNRStoryline
{
private:
   CStructure*       m_mn1;
   CStructure*       m_w1;
   CStructure*       m_d1;
   CStructure*       m_h4;
   CMSNRLevels*      m_mn1L;
   CMSNRLevels*      m_w1L;
   CMSNRLevels*      m_d1L;
   double            m_equalTolAtr;
   double            m_point;
   MSNR_Story        m_st;

   // A rejection: a fully closed candle whose wick exceeds the key level
   // while its body closes back inside (body close on the other side).
   bool RejectedAt(CStructure* s, const double level, int &dir)
   {
      if(s == NULL || s.BarsCount() < 2)
         return false;
      int n = s.BarsCount();
      for(int i = n - 3; i <= n - 1; i++)
      {
         MqlRates r;
         if(!s.GetRate(i, r))
            continue;
         bool bearishReject = (r.high > level && r.close < level);
         bool bullishReject = (r.low < level && r.close > level);
         if(bearishReject)
         {
            dir = SMC_BEAR;
            return true;
         }
         if(bullishReject)
         {
            dir = SMC_BULL;
            return true;
         }
      }
      return false;
   }

   // A7.1 confirmation = BODY close beyond the relevant swing point on the
   // lower timeframe, in the rejection direction.
   bool BreakoutOn(CStructure* lower, const int dir,
                   double &levelOut)
   {
      if(lower == NULL || lower.BosCount() == 0)
         return false;
      SMC_Bos b;
      lower.GetBosAt(lower.BosCount() - 1, b);
      if(b.dir != dir)
         return false;
      levelOut = b.swingPrice;
      // body close confirmation is already enforced by CStructure when
      // InpBOSByClose = true; with wick BOS we require the close explicitly.
      int n = lower.BarsCount();
      MqlRates r;
      if(!lower.GetRate(n - 1, r))
         return false;
      bool ok = (dir == SMC_BULL) ? (r.close > b.swingPrice)
                                  : (r.close < b.swingPrice);
      return ok;
   }

   void CollectLevels(CMSNRLevels* l, const double price, const int dir,
                      double &arr[], int &count, const int cap,
                      const bool onlyAhead)
   {
      if(l == NULL)
         return;
      for(int i = 0; i < l.Count(); i++)
      {
         MSNR_Level lv;
         if(!l.Get(i, lv) || !lv.active || !lv.fresh)
            continue;
         bool ahead = (dir == SMC_BULL) ? (lv.price > price)
                                        : (lv.price < price);
         if(onlyAhead && !ahead)
            continue;
         if(count >= cap)
            break;
         // insert ordered by distance
         double d = MathAbs(lv.price - price);
         int pos = count;
         for(int k = 0; k < count; k++)
         {
            if(MathAbs(arr[k] - price) > d)
            {
               pos = k;
               break;
            }
         }
         for(int k = count; k > pos; k--)
            arr[k] = arr[k - 1];
         arr[pos] = lv.price;
         count++;
      }
   }

public:
   void Init(CStructure* mn1, CStructure* w1, CStructure* d1, CStructure* h4,
             CMSNRLevels* lmn1, CMSNRLevels* lw1, CMSNRLevels* ld1,
             const double equalTolAtr, const double point)
   {
      m_mn1 = mn1; m_w1 = w1; m_d1 = d1; m_h4 = h4;
      m_mn1L = lmn1; m_w1L = lw1; m_d1L = ld1;
      m_equalTolAtr = equalTolAtr;
      m_point = point;
      Reset();
   }

   void Reset()
   {
      m_st.confirmed = false;
      m_st.dir = SMC_NEUTRAL;
      m_st.rejectTF = PERIOD_D1;
      m_st.breakTF = PERIOD_H4;
      m_st.breakoutLevel = 0.0;
      m_st.targetCount = 0;
      m_st.obstacleCount = 0;
      m_st.lastLiquidityTaken = false;
   }

   MSNR_Story Story() const { return m_st; }

   // A7.1 evaluate all three reject/break pairs. Highest TF wins.
   void Evaluate(const double price)
   {
      Reset();
      int rd = 0;
      double bl = 0.0;

      // Monthly rejects monthly -> W1 break (highest priority)
      if(m_mn1L != NULL && RejectedAt(m_mn1, LevelPriceNear(m_mn1L, price), rd) &&
         BreakoutOn(m_w1, rd, bl))
      {
         m_st.confirmed = true;
         m_st.dir = rd;
         m_st.rejectTF = PERIOD_MN1;
         m_st.breakTF = PERIOD_W1;
         m_st.breakoutLevel = bl;
      }
      // Weekly rejects weekly -> D1 break
      else if(m_w1L != NULL && RejectedAt(m_w1, LevelPriceNear(m_w1L, price), rd) &&
              BreakoutOn(m_d1, rd, bl))
      {
         m_st.confirmed = true;
         m_st.dir = rd;
         m_st.rejectTF = PERIOD_W1;
         m_st.breakTF = PERIOD_D1;
         m_st.breakoutLevel = bl;
      }
      // Daily rejects daily -> H4 break
      else if(m_d1L != NULL && RejectedAt(m_d1, LevelPriceNear(m_d1L, price), rd) &&
              BreakoutOn(m_h4, rd, bl))
      {
         m_st.confirmed = true;
         m_st.dir = rd;
         m_st.rejectTF = PERIOD_D1;
         m_st.breakTF = PERIOD_H4;
         m_st.breakoutLevel = bl;
      }

      if(!m_st.confirmed)
         return;

      // A7.2 targets: same or higher TF levels ahead of price.
      CollectLevels(m_d1L, price, m_st.dir,
                    m_st.targets, m_st.targetCount, 3, true);
      if(m_st.targetCount < 3 && m_w1L != NULL)
         CollectLevels(m_w1L, price, m_st.dir,
                       m_st.targets, m_st.targetCount, 3, true);
      if(m_st.targetCount < 3 && m_mn1L != NULL)
         CollectLevels(m_mn1L, price, m_st.dir,
                       m_st.targets, m_st.targetCount, 3, true);

      // obstacles: same TF and one TF lower levels (all levels nearby).
      CollectLevels(m_d1L, price, m_st.dir,
                    m_st.obstacles, m_st.obstacleCount, 8, false);

      // A7.3 last liquidity: equal highs/lows between price and the entry.
      double tol = m_equalTolAtr * ((m_d1 != NULL) ? m_d1.AtrLast() : m_point);
      CStructure* ref = (m_st.rejectTF == PERIOD_MN1) ? m_mn1 :
                        (m_st.rejectTF == PERIOD_W1) ? m_w1 : m_d1;
      if(ref != NULL)
      {
         bool liq = (m_st.dir == SMC_BULL)
                  ? (ref.CountEqualLevels(true, price, tol, true) > 0)
                  : (ref.CountEqualLevels(false, price, tol, true) > 0);
         m_st.lastLiquidityTaken = !liq || (ref.CountEqualLevels(
            m_st.dir == SMC_BULL, price, tol, false) == 0);
      }
   }

private:
   double LevelPriceNear(CMSNRLevels* l, const double price)
   {
      double best = price;
      double bd = 1e18;
      for(int i = 0; i < l.Count(); i++)
      {
         MSNR_Level lv;
         if(!l.Get(i, lv) || !lv.active || !lv.fresh)
            continue;
         if(MathAbs(lv.price - price) < bd)
         {
            bd = MathAbs(lv.price - price);
            best = lv.price;
         }
      }
      return best;
   }
};

#endif // MSNR_STORYLINE_MQH
