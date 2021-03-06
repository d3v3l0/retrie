-- Copyright (c) Facebook, Inc. and its affiliates.
--
-- This source code is licensed under the MIT license found in the
-- LICENSE file in the root directory of this source tree.
--
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
module Retrie.PatternMap.Instances where

import Control.Monad
import Data.ByteString (ByteString)
import Data.Maybe

import Retrie.AlphaEnv
import Retrie.ExactPrint
import Retrie.GHC
import Retrie.PatternMap.Bag
import Retrie.PatternMap.Class
import Retrie.Quantifiers
import Retrie.Substitution

------------------------------------------------------------------------

data TupArgMap a
  = TupArgMap { tamPresent :: EMap a, tamMissing :: MaybeMap a }
  deriving (Functor)

instance PatternMap TupArgMap where
  type Key TupArgMap = LHsTupArg GhcPs

  mEmpty :: TupArgMap a
  mEmpty = TupArgMap mEmpty mEmpty

  mUnion :: TupArgMap a -> TupArgMap a -> TupArgMap a
  mUnion m1 m2 = TupArgMap
    { tamPresent = unionOn tamPresent m1 m2
    , tamMissing = unionOn tamMissing m1 m2
    }

  mAlter :: AlphaEnv -> Quantifiers -> Key TupArgMap -> A a -> TupArgMap a -> TupArgMap a
  mAlter env vs tupArg f m = go (unLoc tupArg)
    where
#if __GLASGOW_HASKELL__ < 806
      go (Present e) = m { tamPresent = mAlter env vs e  f (tamPresent m) }
#else
      go (Present _ e) = m { tamPresent = mAlter env vs e  f (tamPresent m) }
      go XTupArg{} = missingSyntax "XTupArg"
#endif
      go (Missing _) = m { tamMissing = mAlter env vs () f (tamMissing m) }

  mMatch :: MatchEnv -> Key TupArgMap -> (Substitution, TupArgMap a) -> [(Substitution, a)]
  mMatch env = go . unLoc
    where
#if __GLASGOW_HASKELL__ < 806
      go (Present e) = mapFor tamPresent >=> mMatch env e
#else
      go (Present _ e) = mapFor tamPresent >=> mMatch env e
      go XTupArg{} = const []
#endif
      go (Missing _) = mapFor tamMissing >=> mMatch env ()

------------------------------------------------------------------------

data BoxityMap a
  = BoxityMap { boxBoxed :: MaybeMap a, boxUnboxed :: MaybeMap a }
  deriving (Functor)

instance PatternMap BoxityMap where
  type Key BoxityMap = Boxity

  mEmpty :: BoxityMap a
  mEmpty = BoxityMap mEmpty mEmpty

  mUnion :: BoxityMap a -> BoxityMap a -> BoxityMap a
  mUnion m1 m2 = BoxityMap
    { boxBoxed = unionOn boxBoxed m1 m2
    , boxUnboxed = unionOn boxUnboxed m1 m2
    }

  mAlter :: AlphaEnv -> Quantifiers -> Key BoxityMap -> A a -> BoxityMap a -> BoxityMap a
  mAlter env vs Boxed   f m = m { boxBoxed   = mAlter env vs () f (boxBoxed m) }
  mAlter env vs Unboxed f m = m { boxUnboxed = mAlter env vs () f (boxUnboxed m) }

  mMatch :: MatchEnv -> Key BoxityMap -> (Substitution, BoxityMap a) -> [(Substitution, a)]
  mMatch env Boxed   = mapFor boxBoxed >=> mMatch env ()
  mMatch env Unboxed = mapFor boxUnboxed >=> mMatch env ()

------------------------------------------------------------------------

data VMap a = VM { bvmap :: IntMap a, fvmap :: FSEnv a }
            | VMEmpty
  deriving (Functor)

instance PatternMap VMap where
  type Key VMap = RdrName

  mEmpty :: VMap a
  mEmpty = VMEmpty

  mUnion :: VMap a -> VMap a -> VMap a
  mUnion VMEmpty m = m
  mUnion m VMEmpty = m
  mUnion m1 m2 = VM
    { bvmap = unionOn bvmap m1 m2
    , fvmap = unionOn fvmap m1 m2
    }

  mAlter :: AlphaEnv -> Quantifiers -> Key VMap -> A a -> VMap a -> VMap a
  mAlter env vs v f VMEmpty = mAlter env vs v f (VM mEmpty mEmpty)
  mAlter env vs v f m@VM{}
    | Just bv <- lookupAlphaEnv v env = m { bvmap = mAlter env vs bv f (bvmap m) }
    | otherwise                       = m { fvmap = mAlter env vs (rdrFS v) f (fvmap m) }

  mMatch :: MatchEnv -> Key VMap -> (Substitution, VMap a) -> [(Substitution, a)]
  mMatch _   _ (_,VMEmpty) = []
  mMatch env v (hs,m@VM{})
    | Just bv <- lookupAlphaEnv v (meAlphaEnv env) = mMatch env bv (hs, bvmap m)
    | otherwise = mMatch env (rdrFS v) (hs, fvmap m)

------------------------------------------------------------------------

data LMap a
  = LMEmpty
  | LM { lmChar :: Map Char a
       , lmCharPrim :: Map Char a
       , lmString :: FSEnv a
       , lmStringPrim :: Map ByteString a
       , lmInt :: BoolMap (Map Integer a)
       , lmIntPrim :: Map Integer a
       , lmWordPrim :: Map Integer a
       , lmInt64Prim :: Map Integer a
       , lmWord64Prim :: Map Integer a
       }
  deriving (Functor)

emptyLMapWrapper :: LMap a
emptyLMapWrapper
  = LM mEmpty mEmpty mEmpty mEmpty mEmpty
       mEmpty mEmpty mEmpty mEmpty

instance PatternMap LMap where
  type Key LMap = HsLit GhcPs

  mEmpty :: LMap a
  mEmpty = LMEmpty

  mUnion :: LMap a -> LMap a -> LMap a
  mUnion LMEmpty m = m
  mUnion m LMEmpty = m
  mUnion m1 m2 = LM
    { lmChar = unionOn lmChar m1 m2
    , lmCharPrim = unionOn lmCharPrim m1 m2
    , lmString = unionOn lmString m1 m2
    , lmStringPrim = unionOn lmStringPrim m1 m2
    , lmInt = unionOn lmInt m1 m2
    , lmIntPrim = unionOn lmIntPrim m1 m2
    , lmWordPrim = unionOn lmWordPrim m1 m2
    , lmInt64Prim = unionOn lmInt64Prim m1 m2
    , lmWord64Prim = unionOn lmWord64Prim m1 m2
    }

  mAlter :: AlphaEnv -> Quantifiers -> Key LMap -> A a -> LMap a -> LMap a
  mAlter env vs lit f LMEmpty = mAlter env vs lit f emptyLMapWrapper
  mAlter env vs lit f m@LM{}  = go lit
    where
      go (HsChar _ c)       = m { lmChar = mAlter env vs c f (lmChar m) }
      go (HsCharPrim _ c)   = m { lmCharPrim = mAlter env vs c f (lmCharPrim m) }
      go (HsString _ fs)    = m { lmString = mAlter env vs fs f (lmString m) }
      go (HsStringPrim _ bs) = m { lmStringPrim = mAlter env vs bs f (lmStringPrim m) }
      go (HsInt _ (IL _ b i)) =
        m { lmInt = mAlter env vs b (toA (mAlter env vs i f)) (lmInt m) }
      go (HsIntPrim _ i)    = m { lmIntPrim = mAlter env vs i f (lmIntPrim m) }
      go (HsWordPrim _ i)   = m { lmWordPrim = mAlter env vs i f (lmWordPrim m) }
      go (HsInt64Prim _ i)  = m { lmInt64Prim = mAlter env vs i f (lmInt64Prim m) }
      go (HsWord64Prim _ i) = m { lmWord64Prim = mAlter env vs i f (lmWord64Prim m) }
      go (HsInteger _ _ _) = missingSyntax "HsInteger"
      go HsRat{} = missingSyntax "HsRat"
      go HsFloatPrim{} = missingSyntax "HsFloatPrim"
      go HsDoublePrim{} = missingSyntax "HsDoublePrim"
#if __GLASGOW_HASKELL__ < 806
#else
      go XLit{} = missingSyntax "XLit"
#endif

  mMatch :: MatchEnv -> Key LMap -> (Substitution, LMap a) -> [(Substitution, a)]
  mMatch _   _   (_,LMEmpty) = []
  mMatch env lit (hs,m@LM{}) = go lit (hs,m)
    where
      go (HsChar _ c)        = mapFor lmChar >=> mMatch env c
      go (HsCharPrim _ c)    = mapFor lmCharPrim >=> mMatch env c
      go (HsString _ fs)     = mapFor lmString >=> mMatch env fs
      go (HsStringPrim _ bs) = mapFor lmStringPrim >=> mMatch env bs
      go (HsInt _ (IL _ b i)) = mapFor lmInt >=> mMatch env b >=> mMatch env i
      go (HsIntPrim _ i)     = mapFor lmIntPrim >=> mMatch env i
      go (HsWordPrim _ i)    = mapFor lmWordPrim >=> mMatch env i
      go (HsInt64Prim _ i)   = mapFor lmInt64Prim >=> mMatch env i
      go (HsWord64Prim _ i)  = mapFor lmWord64Prim >=> mMatch env i
      go _ = const [] -- TODO

------------------------------------------------------------------------

data OLMap a
  = OLMEmpty
  | OLM
    { olmIntegral :: BoolMap (Map Integer a)
    , olmFractional :: Map Rational a
    , olmIsString :: FSEnv a
    }
  deriving (Functor)

emptyOLMapWrapper :: OLMap a
emptyOLMapWrapper = OLM mEmpty mEmpty mEmpty

instance PatternMap OLMap where
  type Key OLMap = OverLitVal

  mEmpty :: OLMap a
  mEmpty = OLMEmpty

  mUnion :: OLMap a -> OLMap a -> OLMap a
  mUnion OLMEmpty m = m
  mUnion m OLMEmpty = m
  mUnion m1 m2 = OLM
    { olmIntegral = unionOn olmIntegral m1 m2
    , olmFractional = unionOn olmFractional m1 m2
    , olmIsString = unionOn olmIsString m1 m2
    }

  mAlter :: AlphaEnv -> Quantifiers -> Key OLMap -> A a -> OLMap a -> OLMap a
  mAlter env vs lv f OLMEmpty = mAlter env vs lv f emptyOLMapWrapper
  mAlter env vs lv f m@OLM{}  = go lv
    where
      go (HsIntegral (IL _ b i)) =
        m { olmIntegral = mAlter env vs b (toA (mAlter env vs i f)) (olmIntegral m) }
      go (HsFractional fl) = m { olmFractional = mAlter env vs (fl_value fl) f (olmFractional m) }
      go (HsIsString _ fs) = m { olmIsString = mAlter env vs fs f (olmIsString m) }

  mMatch :: MatchEnv -> Key OLMap -> (Substitution, OLMap a) -> [(Substitution, a)]
  mMatch _   _  (_,OLMEmpty) = []
  mMatch env lv (hs,m@OLM{}) = go lv (hs,m)
    where
      go (HsIntegral (IL _ b i)) =
        mapFor olmIntegral >=> mMatch env b >=> mMatch env i
      go (HsFractional fl) = mapFor olmFractional >=> mMatch env (fl_value fl)
      go (HsIsString _ fs) = mapFor olmIsString >=> mMatch env fs

------------------------------------------------------------------------

-- Note [Holes]
-- Holes are distinguished variables which can match any expression. (The
-- universally quantified variables in an Equality.) Ideally, they would be
-- stored as a TyMap, so the type of the expression can be checked against the
-- type of the hole. Fixing this is a TODO. This wraps a map from RdrName to
-- result. We use a regular map instead of a OccEnv so we can get the RdrName
-- back, which allows us to assign it to the expression when building the
-- result.

-- Note [Lambdas]
-- This currently stores both HsLam and HsLamCase

-- Note [Stmt Lists]
-- Statement lists bind to the right, so we need to extend the environment
-- as we move down it. Thus we cannot simply store them as ListMap SMap a.

-- Note [Dollar Fork]
-- When 'f $ x' appears in the pattern, we insert two things in the EMap
-- instead of just one:
--
-- * The original infix application of ($).
-- * The expression transformed into a normal application with parens around
--   the right argument to ($). i.e. f (x)
--
-- This allows us to put ($) in the LHS of rewrites and match both literal ($)
-- applications and the parenthesized equivalent.

data EMap a
  = EMEmpty
  | EM { emHole  :: Map RdrName a -- See Note [Holes]
       , emVar   :: VMap a
       , emIPVar :: FSEnv a
       , emOverLit :: OLMap a
       , emLit   :: LMap a
       , emLam   :: MGMap a -- See Note [Lambdas]
       , emApp   :: EMap (EMap a)
       , emOpApp :: EMap (EMap (EMap a)) -- op, lhs, rhs
       , emNegApp :: EMap a
       , emPar   :: EMap a
       , emExplicitTuple :: BoxityMap (ListMap TupArgMap a)
       , emCase  :: EMap (MGMap a)
       , emSecL  :: EMap (EMap a) -- operator, operand (flipped)
       , emSecR  :: EMap (EMap a) -- operator, operand
       , emIf    :: EMap (EMap (EMap a)) -- cond, true, false
       , emLet   :: LBMap (EMap a)
       , emDo    :: SCMap (SLMap a) -- See Note [Stmt Lists]
       , emExplicitList :: ListMap EMap a
       , emRecordCon :: VMap (ListMap RFMap a)
       , emRecordUpd :: EMap (ListMap RFMap a)
       , emExprWithTySig :: EMap (TyMap a)
       }
  deriving (Functor)

emptyEMapWrapper :: EMap a
emptyEMapWrapper =
  EM mEmpty mEmpty mEmpty mEmpty mEmpty
     mEmpty mEmpty mEmpty mEmpty mEmpty
     mEmpty mEmpty mEmpty mEmpty mEmpty
     mEmpty mEmpty mEmpty mEmpty mEmpty
     mEmpty

instance PatternMap EMap where
  type Key EMap = LHsExpr GhcPs

  mEmpty :: EMap a
  mEmpty = EMEmpty

  mUnion :: EMap a -> EMap a -> EMap a
  mUnion EMEmpty m = m
  mUnion m EMEmpty = m
  mUnion m1 m2 = EM
    { emHole = unionOn emHole m1 m2
    , emVar = unionOn emVar m1 m2
    , emIPVar = unionOn emIPVar m1 m2
    , emOverLit = unionOn emOverLit m1 m2
    , emLit = unionOn emLit m1 m2
    , emLam = unionOn emLam m1 m2
    , emApp = unionOn emApp m1 m2
    , emOpApp = unionOn emOpApp m1 m2
    , emNegApp = unionOn emNegApp m1 m2
    , emPar = unionOn emPar m1 m2
    , emExplicitTuple = unionOn emExplicitTuple m1 m2
    , emCase = unionOn emCase m1 m2
    , emSecL = unionOn emSecL m1 m2
    , emSecR = unionOn emSecR m1 m2
    , emIf = unionOn emIf m1 m2
    , emLet = unionOn emLet m1 m2
    , emDo = unionOn emDo m1 m2
    , emExplicitList = unionOn emExplicitList m1 m2
    , emRecordCon = unionOn emRecordCon m1 m2
    , emRecordUpd = unionOn emRecordUpd m1 m2
    , emExprWithTySig = unionOn emExprWithTySig m1 m2
    }

  mAlter :: AlphaEnv -> Quantifiers -> Key EMap -> A a -> EMap a -> EMap a
  mAlter env vs e f EMEmpty = mAlter env vs e f emptyEMapWrapper
  mAlter env vs e f m@EM{} = go (unLoc e)
    where
      -- See Note [Dollar Fork]
      dollarFork v@HsVar{} l r
        | Just (L _ rdr) <- varRdrName v
        , occNameString (occName rdr) == "$" =
#if __GLASGOW_HASKELL__ < 806
          go (HsApp l (noLoc (HsPar r)))
#else
          go (HsApp noExtField l (noLoc (HsPar noExtField r)))
#endif
      dollarFork _ _ _ = m

#if __GLASGOW_HASKELL__ < 806
      go (HsVar v)
        | unLoc v `isQ` vs = m { emHole  = mAlter env vs (unLoc v) f (emHole m) }
        | otherwise        = m { emVar   = mAlter env vs (unLoc v) f (emVar m) }
      go (ExplicitTuple as b) =
        m { emExplicitTuple = mAlter env vs b (toA (mAlter env vs as f)) (emExplicitTuple m) }
      go (HsApp l r) =
        m { emApp = mAlter env vs l (toA (mAlter env vs r f)) (emApp m) }
      go (HsCase s mg) =
        m { emCase = mAlter env vs s (toA (mAlter env vs mg f)) (emCase m) }
      go (HsDo sc ss _) =
        m { emDo = mAlter env vs sc (toA (mAlter env vs (unLoc ss) f)) (emDo m) }
      go (HsIf _ c tr fl) =
        m { emIf = mAlter env vs c
                      (toA (mAlter env vs tr
                          (toA (mAlter env vs fl f)))) (emIf m) }
      go (HsIPVar (HsIPName ip)) = m { emIPVar = mAlter env vs ip f (emIPVar m) }
      go (HsLit l) = m { emLit   = mAlter env vs l f (emLit m) }
      go (HsLam mg) = m { emLam   = mAlter env vs mg f (emLam m) }
      go (HsOverLit ol) = m { emOverLit = mAlter env vs (ol_val ol) f (emOverLit m) }
      go (NegApp e' _) = m { emNegApp = mAlter env vs e' f (emNegApp m) }
      go (HsPar e') = m { emPar  = mAlter env vs e' f (emPar m) }
      go (OpApp l o _ r) = (dollarFork (unLoc o) l r)
        { emOpApp = mAlter env vs o (toA (mAlter env vs l (toA (mAlter env vs r f)))) (emOpApp m) }
      go (RecordCon v _ _ fs) =
        m { emRecordCon = mAlter env vs (unLoc v) (toA (mAlter env vs (fieldsToRdrNames $ rec_flds fs) f)) (emRecordCon m) }
      go (RecordUpd e' fs _ _ _ _) =
        m { emRecordUpd = mAlter env vs e' (toA (mAlter env vs (fieldsToRdrNames fs) f)) (emRecordUpd m) }
      go (SectionL lhs o) =
        m { emSecL = mAlter env vs o (toA (mAlter env vs lhs f)) (emSecL m) }
      go (SectionR o rhs) =
        m { emSecR = mAlter env vs o (toA (mAlter env vs rhs f)) (emSecR m) }
      go (HsLet lbs e') =
#else
      go (HsVar _ v)
        | unLoc v `isQ` vs = m { emHole  = mAlter env vs (unLoc v) f (emHole m) }
        | otherwise        = m { emVar   = mAlter env vs (unLoc v) f (emVar m) }
      go (ExplicitTuple _ as b) =
        m { emExplicitTuple = mAlter env vs b (toA (mAlter env vs as f)) (emExplicitTuple m) }
      go (HsApp _ l r) =
        m { emApp = mAlter env vs l (toA (mAlter env vs r f)) (emApp m) }
      go (HsCase _ s mg) =
        m { emCase = mAlter env vs s (toA (mAlter env vs mg f)) (emCase m) }
      go (HsDo _ sc ss) =
        m { emDo = mAlter env vs sc (toA (mAlter env vs (unLoc ss) f)) (emDo m) }
      go (HsIf _ _ c tr fl) =
        m { emIf = mAlter env vs c
                      (toA (mAlter env vs tr
                          (toA (mAlter env vs fl f)))) (emIf m) }
      go (HsIPVar _ (HsIPName ip)) = m { emIPVar = mAlter env vs ip f (emIPVar m) }
      go (HsLit _ l) = m { emLit   = mAlter env vs l f (emLit m) }
      go (HsLam _ mg) = m { emLam   = mAlter env vs mg f (emLam m) }
      go (HsOverLit _ ol) = m { emOverLit = mAlter env vs (ol_val ol) f (emOverLit m) }
      go (NegApp _ e' _) = m { emNegApp = mAlter env vs e' f (emNegApp m) }
      go (HsPar _ e') = m { emPar  = mAlter env vs e' f (emPar m) }
      go (OpApp _ l o r) = (dollarFork (unLoc o) l r)
        { emOpApp = mAlter env vs o (toA (mAlter env vs l (toA (mAlter env vs r f)))) (emOpApp m) }
      go (RecordCon _ v fs) =
        m { emRecordCon = mAlter env vs (unLoc v) (toA (mAlter env vs (fieldsToRdrNames $ rec_flds fs) f)) (emRecordCon m) }
      go (RecordUpd _ e' fs) =
        m { emRecordUpd = mAlter env vs e' (toA (mAlter env vs (fieldsToRdrNames fs) f)) (emRecordUpd m) }
      go (SectionL _ lhs o) =
        m { emSecL = mAlter env vs o (toA (mAlter env vs lhs f)) (emSecL m) }
      go (SectionR _ o rhs) =
        m { emSecR = mAlter env vs o (toA (mAlter env vs rhs f)) (emSecR m) }
      go XExpr{} = missingSyntax "XExpr"
      go (HsLet _ lbs e') =
#endif
        let
          bs = collectLocalBinders $ unLoc lbs
          env' = foldr extendAlphaEnvInternal env bs
          vs' = vs `exceptQ` bs
        in m { emLet = mAlter env vs (unLoc lbs) (toA (mAlter env' vs' e' f)) (emLet m) }
      go HsLamCase{} = missingSyntax "HsLamCase"
      go HsMultiIf{} = missingSyntax "HsMultiIf"
      go (ExplicitList _ _ es) = m { emExplicitList = mAlter env vs es f (emExplicitList m) }
      go ArithSeq{} = missingSyntax "ArithSeq"
#if __GLASGOW_HASKELL__ < 806
      go (ExprWithTySig e' (HsWC _ (HsIB _ ty _))) =
        m { emExprWithTySig = mAlter env vs e' (toA (mAlter env vs ty f)) (emExprWithTySig m) }
#else
#if __GLASGOW_HASKELL__ < 808
      go (ExprWithTySig (HsWC _ (HsIB _ ty)) e') =
#else
      go (ExprWithTySig _ e' (HsWC _ (HsIB _ ty))) =
#endif
        m { emExprWithTySig = mAlter env vs e' (toA (mAlter env vs ty f)) (emExprWithTySig m) }
      go ExprWithTySig{} = missingSyntax "ExprWithTySig"
#endif
      go HsSCC{} = missingSyntax "HsSCC"
      go HsCoreAnn{} = missingSyntax "HsCoreAnn"
      go HsBracket{} = missingSyntax "HsBracket"
      go HsRnBracketOut{} = missingSyntax "HsRnBracketOut"
      go HsTcBracketOut{} = missingSyntax "HsTcBracketOut"
      go HsSpliceE{} = missingSyntax "HsSpliceE"
      go HsProc{} = missingSyntax "HsProc"
      go HsStatic{} = missingSyntax "HsStatic"
#if __GLASGOW_HASKELL__ < 810
      go HsArrApp{} = missingSyntax "HsArrApp"
      go HsArrForm{} = missingSyntax "HsArrForm"
      go EWildPat{} = missingSyntax "EWildPat"
      go EAsPat{} = missingSyntax "EAsPat"
      go EViewPat{} = missingSyntax "EViewPat"
      go ELazyPat{} = missingSyntax "ELazyPat"
#endif
      go HsTick{} = missingSyntax "HsTick"
      go HsBinTick{} = missingSyntax "HsBinTick"
      go HsTickPragma{} = missingSyntax "HsTickPragma"
      go HsWrap{} = missingSyntax "HsWrap"
      go HsUnboundVar{} = missingSyntax "HsUnboundVar"
      go HsRecFld{} = missingSyntax "HsRecFld"
      go HsOverLabel{} = missingSyntax "HsOverLabel"
      go HsAppType{} = missingSyntax "HsAppType"
      go HsConLikeOut{} = missingSyntax "HsConLikeOut"
      go ExplicitSum{} = missingSyntax "ExplicitSum"
#if __GLASGOW_HASKELL__ < 806
      go ExplicitPArr{} = missingSyntax "ExplicitPArr"
      go ExprWithTySigOut{} = missingSyntax "ExprWithTySigOut"
      go HsAppTypeOut{} = missingSyntax "HsAppTypeOut"
      go PArrSeq{} = missingSyntax "PArrSeq"
#endif

  mMatch :: MatchEnv -> Key EMap -> (Substitution, EMap a) -> [(Substitution, a)]
  mMatch _   _ (_,EMEmpty) = []
  mMatch env e (hs,m@EM{}) = hss ++ go (unLoc e) (hs,m)
    where
      hss = extendResult (emHole m) (HoleExpr $ mePruneA env e) hs

#if __GLASGOW_HASKELL__ < 806
      go (ExplicitTuple as b) = mapFor emExplicitTuple >=> mMatch env b >=> mMatch env as
      go (HsApp l r) = mapFor emApp >=> mMatch env l >=> mMatch env r
      go (HsCase s mg) = mapFor emCase >=> mMatch env s >=> mMatch env mg
      go (HsDo sc ss _) = mapFor emDo >=> mMatch env sc >=> mMatch env (unLoc ss)
      go (HsIf _ c tr fl) =
        mapFor emIf >=> mMatch env c >=> mMatch env tr >=> mMatch env fl
      go (HsIPVar (HsIPName ip)) = mapFor emIPVar >=> mMatch env ip
      go (HsLam mg) = mapFor emLam >=> mMatch env mg
      go (HsLit l) = mapFor emLit >=> mMatch env l
      go (HsOverLit ol) = mapFor emOverLit >=> mMatch env (ol_val ol)
      go (HsPar e') = mapFor emPar >=> mMatch env e'
      go (HsVar v) = mapFor emVar >=> mMatch env (unLoc v)
      go (NegApp e' _) = mapFor emNegApp >=> mMatch env e'
      go (OpApp l o _ r) =
        mapFor emOpApp >=> mMatch env o >=> mMatch env l >=> mMatch env r
      go (RecordCon v _ _ fs) =
        mapFor emRecordCon >=> mMatch env (unLoc v) >=> mMatch env (fieldsToRdrNames $ rec_flds fs)
      go (RecordUpd e' fs _ _ _ _) =
        mapFor emRecordUpd >=> mMatch env e' >=> mMatch env (fieldsToRdrNames fs)
      go (SectionL lhs o) = mapFor emSecL >=> mMatch env o >=> mMatch env lhs
      go (SectionR o rhs) = mapFor emSecR >=> mMatch env o >=> mMatch env rhs
      go (HsLet lbs e') =
#else
      go (ExplicitTuple _ as b) = mapFor emExplicitTuple >=> mMatch env b >=> mMatch env as
      go (HsApp _ l r) = mapFor emApp >=> mMatch env l >=> mMatch env r
      go (HsCase _ s mg) = mapFor emCase >=> mMatch env s >=> mMatch env mg
      go (HsDo _ sc ss) = mapFor emDo >=> mMatch env sc >=> mMatch env (unLoc ss)
      go (HsIf _ _ c tr fl) =
        mapFor emIf >=> mMatch env c >=> mMatch env tr >=> mMatch env fl
      go (HsIPVar _ (HsIPName ip)) = mapFor emIPVar >=> mMatch env ip
      go (HsLam _ mg) = mapFor emLam >=> mMatch env mg
      go (HsLit _ l) = mapFor emLit >=> mMatch env l
      go (HsOverLit _ ol) = mapFor emOverLit >=> mMatch env (ol_val ol)
      go (HsPar _ e') = mapFor emPar >=> mMatch env e'
      go (HsVar _ v) = mapFor emVar >=> mMatch env (unLoc v)
      go (OpApp _ l o r) =
        mapFor emOpApp >=> mMatch env o >=> mMatch env l >=> mMatch env r
      go (NegApp _ e' _) = mapFor emNegApp >=> mMatch env e'
      go (RecordCon _ v fs) =
        mapFor emRecordCon >=> mMatch env (unLoc v) >=> mMatch env (fieldsToRdrNames $ rec_flds fs)
      go (RecordUpd _ e' fs) =
        mapFor emRecordUpd >=> mMatch env e' >=> mMatch env (fieldsToRdrNames fs)
      go (SectionL _ lhs o) = mapFor emSecL >=> mMatch env o >=> mMatch env lhs
      go (SectionR _ o rhs) = mapFor emSecR >=> mMatch env o >=> mMatch env rhs
      go (HsLet _ lbs e') =
#endif
        let
          bs = collectLocalBinders (unLoc lbs)
          env' = extendMatchEnv env bs
        in mapFor emLet >=> mMatch env (unLoc lbs) >=> mMatch env' e'
      go (ExplicitList _ _ es) = mapFor emExplicitList >=> mMatch env es
#if __GLASGOW_HASKELL__ < 806
      go (ExprWithTySig e' (HsWC _ (HsIB _ ty _))) =
#elif __GLASGOW_HASKELL__ < 808
      go (ExprWithTySig (HsWC _ (HsIB _ ty)) e') =
#else
      go (ExprWithTySig _ e' (HsWC _ (HsIB _ ty))) =
#endif
        mapFor emExprWithTySig >=> mMatch env e' >=> mMatch env ty
      go _ = const [] -- TODO remove

-- Add the matched expression to the holes map, fails if expression differs from one already in hole.
extendResult :: Map RdrName a -> HoleVal -> Substitution -> [(Substitution, a)]
extendResult hm v sub = catMaybes
  [ case lookupSubst n sub of
      Nothing -> return (extendSubst sub n v, x)
      Just v' -> sameHoleValue v v' >> return (sub, x)
  | (nm,x) <- mapAssocs hm, let n = rdrFS nm ]

singleton :: [a] -> Maybe a
singleton [x] = Just x
singleton _  = Nothing

-- | Determine if two expressions are alpha-equivalent.
sameHoleValue :: HoleVal -> HoleVal -> Maybe ()
sameHoleValue (HoleExpr e1)  (HoleExpr e2)  =
  alphaEquivalent (astA e1) (astA e2) EMEmpty
sameHoleValue (HolePat p1)   (HolePat p2)   =
  alphaEquivalent
#if __GLASGOW_HASKELL__ < 808
    (astA p1)
    (astA p2)
#else
    (composeSrcSpan $ astA p1)
    (composeSrcSpan $ astA p2)
#endif
    PatEmpty
sameHoleValue (HoleType ty1) (HoleType ty2) =
  alphaEquivalent (astA ty1) (astA ty2) TyEmpty
sameHoleValue _              _              = Nothing

alphaEquivalent :: PatternMap m => Key m -> Key m -> m () -> Maybe ()
alphaEquivalent v1 v2 e = snd <$> singleton (findMatch env v2 m)
  where
    m = insertMatch emptyAlphaEnv emptyQs v1 () e
    env = ME emptyAlphaEnv err
    err _ = error "hole prune during alpha-equivalence check is impossible!"

------------------------------------------------------------------------

data SCMap a
  = SCEmpty
  | SCM { scmListComp :: MaybeMap a
        , scmMonadComp :: MaybeMap a
        , scmDoExpr :: MaybeMap a
        -- TODO: the rest
        }
  deriving (Functor)

emptySCMapWrapper :: SCMap a
emptySCMapWrapper = SCM mEmpty mEmpty mEmpty

instance PatternMap SCMap where
  type Key SCMap = HsStmtContext Name -- see comment on HsDo in GHC

  mEmpty :: SCMap a
  mEmpty = SCEmpty

  mUnion :: SCMap a -> SCMap a -> SCMap a
  mUnion SCEmpty m = m
  mUnion m SCEmpty = m
  mUnion m1 m2 = SCM
    { scmListComp = unionOn scmListComp m1 m2
    , scmMonadComp = unionOn scmMonadComp m1 m2
    , scmDoExpr = unionOn scmDoExpr m1 m2
    }

  mAlter :: AlphaEnv -> Quantifiers -> Key SCMap -> A a -> SCMap a -> SCMap a
  mAlter env vs sc f SCEmpty = mAlter env vs sc f emptySCMapWrapper
  mAlter env vs sc f m@SCM{} = go sc
    where
      go ListComp = m { scmListComp = mAlter env vs () f (scmListComp m) }
      go MonadComp = m { scmMonadComp = mAlter env vs () f (scmMonadComp m) }
#if __GLASGOW_HASKELL__ < 806
      go PArrComp = missingSyntax "PArrComp"
#endif
      go DoExpr = m { scmDoExpr = mAlter env vs () f (scmDoExpr m) }
      go MDoExpr = missingSyntax "MDoExpr"
      go ArrowExpr = missingSyntax "ArrowExpr"
      go GhciStmtCtxt = missingSyntax "GhciStmtCtxt"
      go (PatGuard _) = missingSyntax "PatGuard"
      go (ParStmtCtxt _) = missingSyntax "ParStmtCtxt"
      go (TransStmtCtxt _) = missingSyntax "TransStmtCtxt"

  mMatch :: MatchEnv -> Key SCMap -> (Substitution, SCMap a) -> [(Substitution, a)]
  mMatch _   _  (_,SCEmpty)  = []
  mMatch env sc (hs,m@SCM{}) = go sc (hs,m)
    where
      go ListComp = mapFor scmListComp >=> mMatch env ()
      go MonadComp = mapFor scmMonadComp >=> mMatch env ()
      go DoExpr = mapFor scmDoExpr >=> mMatch env ()
      go _ = const [] -- TODO

------------------------------------------------------------------------

-- Note [MatchGroup]
-- A MatchGroup contains a list of argument types and a result type, but
-- these aren't available until after typechecking, so they are all placeholders
-- at this point. Also, don't care about the origin.
newtype MGMap a = MGMap { unMGMap :: ListMap MMap a }
  deriving (Functor)

instance PatternMap MGMap where
  type Key MGMap = MatchGroup GhcPs (LHsExpr GhcPs)

  mEmpty :: MGMap a
  mEmpty = MGMap mEmpty

  mUnion :: MGMap a -> MGMap a -> MGMap a
  mUnion (MGMap m1) (MGMap m2) = MGMap (mUnion m1 m2)

  mAlter :: AlphaEnv -> Quantifiers -> Key MGMap -> A a -> MGMap a -> MGMap a
  mAlter env vs mg f (MGMap m) = MGMap (mAlter env vs alts f m)
    where alts = map unLoc (unLoc $ mg_alts mg)

  mMatch :: MatchEnv -> Key MGMap -> (Substitution, MGMap a) -> [(Substitution, a)]
  mMatch env mg = mapFor unMGMap >=> mMatch env alts
    where alts = map unLoc (unLoc $ mg_alts mg)

------------------------------------------------------------------------

newtype MMap a = MMap { unMMap :: ListMap PatMap (GRHSSMap a) }
  deriving (Functor)

instance PatternMap MMap where
  type Key MMap = Match GhcPs (LHsExpr GhcPs)

  mEmpty :: MMap a
  mEmpty = MMap mEmpty

  mUnion :: MMap a -> MMap a -> MMap a
  mUnion (MMap m1) (MMap m2) = MMap (mUnion m1 m2)

  mAlter :: AlphaEnv -> Quantifiers -> Key MMap -> A a -> MMap a -> MMap a
  mAlter env vs match f (MMap m) =
    let lpats = m_pats match
        pbs = collectPatsBinders lpats
        env' = foldr extendAlphaEnvInternal env pbs
        vs' = vs `exceptQ` pbs
    in MMap (mAlter env vs lpats
              (toA (mAlter env' vs' (m_grhss match) f)) m)

  mMatch :: MatchEnv -> Key MMap -> (Substitution, MMap a) -> [(Substitution, a)]
  mMatch env match = mapFor unMMap >=> mMatch env lpats >=> mMatch env' (m_grhss match)
    where
      lpats = m_pats match
      pbs = collectPatsBinders lpats
      env' = extendMatchEnv env pbs

------------------------------------------------------------------------

data CDMap a
  = CDEmpty
  | CDMap { cdPrefixCon :: ListMap PatMap a
          -- TODO , cdRecCon    :: MaybeMap a
          , cdInfixCon  :: PatMap (PatMap a)
          }
  deriving (Functor)

emptyCDMapWrapper :: CDMap a
emptyCDMapWrapper = CDMap mEmpty mEmpty

instance PatternMap CDMap where
#if __GLASGOW_HASKELL__ < 810
  type Key CDMap = HsConDetails (LPat GhcPs) (HsRecFields GhcPs (LPat GhcPs))
#else
  -- We must manually expand 'LPat' to avoid UndecidableInstances in GHC 8.10+
  type Key CDMap = HsConDetails (Located (Pat GhcPs)) (HsRecFields GhcPs (Located (Pat GhcPs)))
#endif

  mEmpty :: CDMap a
  mEmpty = CDEmpty

  mUnion :: CDMap a -> CDMap a -> CDMap a
  mUnion CDEmpty m = m
  mUnion m CDEmpty = m
  mUnion m1 m2 = CDMap
    { cdPrefixCon = unionOn cdPrefixCon m1 m2
    , cdInfixCon = unionOn cdInfixCon m1 m2
    }

  mAlter :: AlphaEnv -> Quantifiers -> Key CDMap -> A a -> CDMap a -> CDMap a
  mAlter env vs d f CDEmpty   = mAlter env vs d f emptyCDMapWrapper
  mAlter env vs d f m@CDMap{} = go d
    where
      go (PrefixCon ps) = m { cdPrefixCon = mAlter env vs ps f (cdPrefixCon m) }
      go (RecCon _) = missingSyntax "RecCon"
      go (InfixCon p1 p2) = m { cdInfixCon = mAlter env vs p1
                                              (toA (mAlter env vs p2 f))
                                              (cdInfixCon m) }

  mMatch :: MatchEnv -> Key CDMap -> (Substitution, CDMap a) -> [(Substitution, a)]
  mMatch _   _ (_ ,CDEmpty)   = []
  mMatch env d (hs,m@CDMap{}) = go d (hs,m)
    where
      go (PrefixCon ps) = mapFor cdPrefixCon >=> mMatch env ps
      go (InfixCon p1 p2) = mapFor cdInfixCon >=> mMatch env p1 >=> mMatch env p2
      go _ = const [] -- TODO

------------------------------------------------------------------------

-- Note [Variable Binders]
-- We don't actually care about the variable name, since we are checking for
-- alpha-equivalence.

data PatMap a
  = PatEmpty
  | PatMap { pmHole :: Map RdrName a -- See Note [Holes]
           , pmWild :: MaybeMap a
           , pmVar  :: MaybeMap a -- See Note [Variable Binders]
           , pmParPat :: PatMap a
           , pmTuplePat :: BoxityMap (ListMap PatMap a)
           , pmConPatIn :: FSEnv (CDMap a)
           -- TODO: the rest
           }
  deriving (Functor)

emptyPatMapWrapper :: PatMap a
emptyPatMapWrapper = PatMap mEmpty mEmpty mEmpty mEmpty mEmpty mEmpty

instance PatternMap PatMap where
#if __GLASGOW_HASKELL__ < 810
  type Key PatMap = LPat GhcPs
#else
  -- We must manually expand 'LPat' to avoid UndecidableInstances in GHC 8.10+
  type Key PatMap = Located (Pat GhcPs)
#endif

  mEmpty :: PatMap a
  mEmpty = PatEmpty

  mUnion :: PatMap a -> PatMap a -> PatMap a
  mUnion PatEmpty m = m
  mUnion m PatEmpty = m
  mUnion m1 m2 = PatMap
    { pmHole = unionOn pmHole m1 m2
    , pmWild = unionOn pmWild m1 m2
    , pmVar = unionOn pmVar m1 m2
    , pmParPat = unionOn pmParPat m1 m2
    , pmTuplePat = unionOn pmTuplePat m1 m2
    , pmConPatIn = unionOn pmConPatIn m1 m2
    }

  mAlter :: AlphaEnv -> Quantifiers -> Key PatMap -> A a -> PatMap a -> PatMap a
  mAlter env vs pat f PatEmpty   = mAlter env vs pat f emptyPatMapWrapper
  mAlter env vs pat f m@PatMap{} = go (unLoc pat)
    where
      go (WildPat _) = m { pmWild = mAlter env vs () f (pmWild m) }
#if __GLASGOW_HASKELL__ < 806
      go (VarPat v)
#else
      go (VarPat _ v)
#endif
        | unLoc v `isQ` vs = m { pmHole  = mAlter env vs (unLoc v) f (pmHole m) }
        | otherwise        = m { pmVar   = mAlter env vs () f (pmVar m) } -- See Note [Variable Binders]
      go LazyPat{} = missingSyntax "LazyPat"
      go AsPat{} = missingSyntax "AsPat"
      go BangPat{} = missingSyntax "BangPat"
      go ListPat{} = missingSyntax "ListPat"
      go (ConPatIn c d) = m { pmConPatIn = mAlter env vs (rdrFS (unLoc c)) (toA (mAlter env vs d f)) (pmConPatIn m) }
      go ConPatOut{} = missingSyntax "ConPatOut"
      go ViewPat{} = missingSyntax "ViewPat"
      go SplicePat{} = missingSyntax "SplicePat"
      go LitPat{} = missingSyntax "LitPat"
      go NPat{} = missingSyntax "NPat"
      go NPlusKPat{} = missingSyntax "NPlusKPat"
#if __GLASGOW_HASKELL__ < 806
      go (PArrPat _ _) = missingSyntax "PArrPat"
      go (ParPat p) = m { pmParPat = mAlter env vs p f (pmParPat m) }
      go (SigPatIn _ _) = missingSyntax "SigPatIn"
      go (SigPatOut _ _) = missingSyntax "SigPatOut"
      go (TuplePat ps b _tys) =
        m { pmTuplePat = mAlter env vs b (toA (mAlter env vs ps f)) (pmTuplePat m) }
#else
      go (ParPat _ p) = m { pmParPat = mAlter env vs p f (pmParPat m) }
      go (TuplePat _ ps b) =
        m { pmTuplePat = mAlter env vs b (toA (mAlter env vs ps f)) (pmTuplePat m) }
      go SigPat{} = missingSyntax "SigPat"
      go XPat{} = missingSyntax "XPat"
#endif
      go CoPat{} = missingSyntax "CoPat"
      go SumPat{} = missingSyntax "SumPat"

  mMatch :: MatchEnv -> Key PatMap -> (Substitution, PatMap a) -> [(Substitution, a)]
  mMatch _   _   (_ ,PatEmpty)   = []
#if __GLASGOW_HASKELL__ < 808
  mMatch env pat (hs,m@PatMap{}) =
#else
  mMatch env (dL -> pat) (hs,m@PatMap{}) =
#endif
    hss ++ go (unLoc pat) (hs,m)
    where
      hss = extendResult (pmHole m) (HolePat $ mePruneA env pat) hs

      go (WildPat _) = mapFor pmWild >=> mMatch env ()
#if __GLASGOW_HASKELL__ < 806
      go (ParPat p) = mapFor pmParPat >=> mMatch env p
      go (TuplePat ps b _) = mapFor pmTuplePat >=> mMatch env b >=> mMatch env ps
      go (VarPat _) = mapFor pmVar >=> mMatch env ()
#else
      go (ParPat _ p) = mapFor pmParPat >=> mMatch env p
      go (TuplePat _ ps b) = mapFor pmTuplePat >=> mMatch env b >=> mMatch env ps
      go (VarPat _ _) = mapFor pmVar >=> mMatch env ()
#endif
      go (ConPatIn c d) = mapFor pmConPatIn >=> mMatch env (rdrFS (unLoc c)) >=> mMatch env d
      go _ = const [] -- TODO

------------------------------------------------------------------------

newtype GRHSSMap a = GRHSSMap { unGRHSSMap :: LBMap (ListMap GRHSMap a) }
  deriving (Functor)

instance PatternMap GRHSSMap where
  type Key GRHSSMap = GRHSs GhcPs (LHsExpr GhcPs)

  mEmpty :: GRHSSMap a
  mEmpty = GRHSSMap mEmpty

  mUnion :: GRHSSMap a -> GRHSSMap a -> GRHSSMap a
  mUnion (GRHSSMap m1) (GRHSSMap m2) = GRHSSMap (mUnion m1 m2)

  mAlter :: AlphaEnv -> Quantifiers -> Key GRHSSMap -> A a -> GRHSSMap a -> GRHSSMap a
  mAlter env vs grhss f (GRHSSMap m) =
    let lbs = unLoc $ grhssLocalBinds grhss
        bs = collectLocalBinders lbs
        env' = foldr extendAlphaEnvInternal env bs
        vs' = vs `exceptQ` bs
    in GRHSSMap (mAlter env vs lbs
                  (toA (mAlter env' vs' (map unLoc $ grhssGRHSs grhss) f)) m)

  mMatch :: MatchEnv -> Key GRHSSMap -> (Substitution, GRHSSMap a) -> [(Substitution, a)]
  mMatch env grhss = mapFor unGRHSSMap >=> mMatch env lbs
                      >=> mMatch env' (map unLoc $ grhssGRHSs grhss)
    where
      lbs = unLoc $ grhssLocalBinds grhss
      bs = collectLocalBinders lbs
      env' = extendMatchEnv env bs

------------------------------------------------------------------------

newtype GRHSMap a = GRHSMap { unGRHSMap :: SLMap (EMap a) }
  deriving (Functor)

instance PatternMap GRHSMap where
  type Key GRHSMap = GRHS GhcPs (LHsExpr GhcPs)

  mEmpty :: GRHSMap a
  mEmpty = GRHSMap mEmpty

  mUnion :: GRHSMap a -> GRHSMap a -> GRHSMap a
  mUnion (GRHSMap m1) (GRHSMap m2) = GRHSMap (mUnion m1 m2)

  mAlter :: AlphaEnv -> Quantifiers -> Key GRHSMap -> A a -> GRHSMap a -> GRHSMap a
#if __GLASGOW_HASKELL__ < 806
  mAlter env vs (GRHS gs b) f (GRHSMap m) =
#else
  mAlter _ _ XGRHS{} _ _ = missingSyntax "XGRHS"
  mAlter env vs (GRHS _ gs b) f (GRHSMap m) =
#endif
    let bs = collectLStmtsBinders gs
        env' = foldr extendAlphaEnvInternal env bs
        vs' = vs `exceptQ` bs
    in GRHSMap (mAlter env vs gs (toA (mAlter env' vs' b f)) m)

  mMatch :: MatchEnv -> Key GRHSMap -> (Substitution, GRHSMap a) -> [(Substitution, a)]
#if __GLASGOW_HASKELL__ < 806
  mMatch env (GRHS gs b) =
#else
  mMatch _ XGRHS{} = const []
  mMatch env (GRHS _ gs b) =
#endif
    mapFor unGRHSMap >=> mMatch env gs >=> mMatch env' b
    where
      bs = collectLStmtsBinders gs
      env' = extendMatchEnv env bs

------------------------------------------------------------------------

data SLMap a
  = SLEmpty
  | SLM { slmNil :: MaybeMap a
        , slmCons :: SMap (SLMap a)
        }
  deriving (Functor)

emptySLMapWrapper :: SLMap a
emptySLMapWrapper = SLM mEmpty mEmpty

instance PatternMap SLMap where
  type Key SLMap = [LStmt GhcPs (LHsExpr GhcPs)]

  mEmpty :: SLMap a
  mEmpty = SLEmpty

  mUnion :: SLMap a -> SLMap a -> SLMap a
  mUnion SLEmpty m = m
  mUnion m SLEmpty = m
  mUnion m1 m2 = SLM
    { slmNil = unionOn slmNil m1 m2
    , slmCons = unionOn slmCons m1 m2
    }

  mAlter :: AlphaEnv -> Quantifiers -> Key SLMap -> A a -> SLMap a -> SLMap a
  mAlter env vs ss f SLEmpty = mAlter env vs ss f emptySLMapWrapper
  mAlter env vs ss f m@SLM{} = go ss
    where
      go []      = m { slmNil = mAlter env vs () f (slmNil m) }
      go (s:ss') =
        let
          bs = collectLStmtBinders s
          env' = foldr extendAlphaEnvInternal env bs
          vs' = vs `exceptQ` bs
        in m { slmCons = mAlter env vs s (toA (mAlter env' vs' ss' f)) (slmCons m) }

  mMatch :: MatchEnv -> Key SLMap -> (Substitution, SLMap a) -> [(Substitution, a)]
  mMatch _   _  (_,SLEmpty)  = []
  mMatch env ss (hs,m@SLM{}) = go ss (hs,m)
    where
      go [] = mapFor slmNil >=> mMatch env ()
      go (s:ss') =
        let
          bs = collectLStmtBinders s
          env' = extendMatchEnv env bs
        in mapFor slmCons >=> mMatch env s >=> mMatch env' ss'

------------------------------------------------------------------------

-- Note [Local Binds]
-- We simplify this a bit here, assuming always ValBindsIn (because ValBindsOut
-- only shows up after renaming. Also we ignore the [LSig] for now.

data LBMap a
  = LBEmpty
  | LB { lbValBinds :: ListMap BMap a -- see Note [Local Binds]
       -- TODO: , lbIPBinds ::
       , lbEmpty :: MaybeMap a
       }
  deriving (Functor)

emptyLBMapWrapper :: LBMap a
emptyLBMapWrapper = LB mEmpty mEmpty

instance PatternMap LBMap where
  type Key LBMap = HsLocalBinds GhcPs

  mEmpty :: LBMap a
  mEmpty = LBEmpty

  mUnion :: LBMap a -> LBMap a -> LBMap a
  mUnion LBEmpty m = m
  mUnion m LBEmpty = m
  mUnion m1 m2 = LB
    { lbValBinds = unionOn lbValBinds m1 m2
    , lbEmpty = unionOn lbEmpty m1 m2
    }

  mAlter :: AlphaEnv -> Quantifiers -> Key LBMap -> A a -> LBMap a -> LBMap a
  mAlter env vs lbs f LBEmpty = mAlter env vs lbs f emptyLBMapWrapper
  mAlter env vs lbs f m@LB{}  = go lbs
    where
#if __GLASGOW_HASKELL__ < 806
      go EmptyLocalBinds = m { lbEmpty = mAlter env vs () f (lbEmpty m) }
      go (HsValBinds vbs) =
#else
      go (EmptyLocalBinds _) = m { lbEmpty = mAlter env vs () f (lbEmpty m) }
      go XHsLocalBindsLR{} = missingSyntax "XHsLocalBindsLR"
      go (HsValBinds _ vbs) =
#endif
        let
          bs = collectHsValBinders vbs
          env' = foldr extendAlphaEnvInternal env bs
          vs' = vs `exceptQ` bs
        in m { lbValBinds = mAlter env' vs' (deValBinds vbs) f (lbValBinds m) }
      go HsIPBinds{} = missingSyntax "HsIPBinds"

  mMatch :: MatchEnv -> Key LBMap -> (Substitution, LBMap a) -> [(Substitution, a)]
  mMatch _   _   (_,LBEmpty) = []
  mMatch env lbs (hs,m@LB{}) = go lbs (hs,m)
    where
#if __GLASGOW_HASKELL__ < 806
      go EmptyLocalBinds = mapFor lbEmpty >=> mMatch env ()
      go (HsValBinds vbs) =
#else
      go (EmptyLocalBinds _) = mapFor lbEmpty >=> mMatch env ()
      go (HsValBinds _ vbs) =
#endif
        let
          bs = collectHsValBinders vbs
          env' = extendMatchEnv env bs
        in mapFor lbValBinds >=> mMatch env' (deValBinds vbs)
      go _ = const [] -- TODO

deValBinds :: HsValBinds GhcPs -> [HsBind GhcPs]
#if __GLASGOW_HASKELL__ < 806
deValBinds (ValBindsIn lbs _) = map unLoc (bagToList lbs)
#else
deValBinds (ValBinds _ lbs _) = map unLoc (bagToList lbs)
#endif
deValBinds _ = error "deValBinds ValBindsOut"

------------------------------------------------------------------------

-- Note [Bind env]
-- We don't extend the env because it was already done at the LBMap level
-- (because all bindings are available to the recursive group).

data BMap a
  = BMEmpty
  | BM { bmFunBind :: MGMap a
       , bmVarBind :: EMap a
       , bmPatBind :: PatMap (GRHSSMap a)
       -- TODO: rest
       }
  deriving (Functor)

emptyBMapWrapper :: BMap a
emptyBMapWrapper = BM mEmpty mEmpty mEmpty

instance PatternMap BMap where
  type Key BMap = HsBind GhcPs

  mEmpty :: BMap a
  mEmpty = BMEmpty

  mUnion :: BMap a -> BMap a -> BMap a
  mUnion BMEmpty m = m
  mUnion m BMEmpty = m
  mUnion m1 m2 = BM
    { bmFunBind = unionOn bmFunBind m1 m2
    , bmVarBind = unionOn bmVarBind m1 m2
    , bmPatBind = unionOn bmPatBind m1 m2
    }

  mAlter :: AlphaEnv -> Quantifiers -> Key BMap -> A a -> BMap a -> BMap a
  mAlter env vs b f BMEmpty = mAlter env vs b f emptyBMapWrapper
  mAlter env vs b f m@BM{}  = go b
    where -- see Note [Bind env]
#if __GLASGOW_HASKELL__ < 806
      go (FunBind _ mg _ _ _) = m { bmFunBind = mAlter env vs mg f (bmFunBind m) }
      go (VarBind _ e _) = m { bmVarBind = mAlter env vs e f (bmVarBind m) }
      go (PatBind lhs rhs _ _ _) =
#else
      go (FunBind _ _ mg _ _) = m { bmFunBind = mAlter env vs mg f (bmFunBind m) }
      go (VarBind _ _ e _) = m { bmVarBind = mAlter env vs e f (bmVarBind m) }
      go XHsBindsLR{} = missingSyntax "XHsBindsLR"
      go (PatBind _ lhs rhs _) =
#endif
        m { bmPatBind = mAlter env vs lhs
              (toA $ mAlter env vs rhs f) (bmPatBind m) }
      go AbsBinds{} = missingSyntax "AbsBinds"
      go PatSynBind{} = missingSyntax "PatSynBind"

  mMatch :: MatchEnv -> Key BMap -> (Substitution, BMap a) -> [(Substitution, a)]
  mMatch _   _ (_,BMEmpty) = []
  mMatch env b (hs,m@BM{}) = go b (hs,m)
    where
#if __GLASGOW_HASKELL__ < 806
      go (FunBind _ mg _ _ _) = mapFor bmFunBind >=> mMatch env mg
      go (VarBind _ e _) = mapFor bmVarBind >=> mMatch env e
      go (PatBind lhs rhs _ _ _)
#else
      go (FunBind _ _ mg _ _)  = mapFor bmFunBind >=> mMatch env mg
      go (VarBind _ _ e _) = mapFor bmVarBind >=> mMatch env e
      go (PatBind _ lhs rhs _)
#endif
        = mapFor bmPatBind >=> mMatch env lhs >=> mMatch env rhs
      go _ = const [] -- TODO

------------------------------------------------------------------------

data SMap a
  = SMEmpty
  | SM { smLastStmt :: EMap a
       , smBindStmt :: PatMap (EMap a)
       , smBodyStmt :: EMap a
         -- TODO: the rest
       }
  deriving (Functor)

emptySMapWrapper :: SMap a
emptySMapWrapper = SM mEmpty mEmpty mEmpty

instance PatternMap SMap where
  type Key SMap = LStmt GhcPs (LHsExpr GhcPs)

  mEmpty :: SMap a
  mEmpty = SMEmpty

  mUnion :: SMap a -> SMap a -> SMap a
  mUnion SMEmpty m = m
  mUnion m SMEmpty = m
  mUnion m1 m2 = SM
    { smLastStmt = unionOn smLastStmt m1 m2
    , smBindStmt = unionOn smBindStmt m1 m2
    , smBodyStmt = unionOn smBodyStmt m1 m2
    }

  mAlter :: AlphaEnv -> Quantifiers -> Key SMap -> A a -> SMap a -> SMap a
  mAlter env vs s f SMEmpty = mAlter env vs s f emptySMapWrapper
  mAlter env vs s f m@(SM {}) = go (unLoc s)
    where
#if __GLASGOW_HASKELL__ < 806
      go (BodyStmt e _ _ _) = m { smBodyStmt = mAlter env vs e f (smBodyStmt m) }
      go (LastStmt e _ _)   = m { smLastStmt = mAlter env vs e f (smLastStmt m) }
      go (BindStmt p e _ _ _) =
#else
      go (BodyStmt _ e _ _) = m { smBodyStmt = mAlter env vs e f (smBodyStmt m) }
      go (LastStmt _ e _ _)   = m { smLastStmt = mAlter env vs e f (smLastStmt m) }
      go XStmtLR{} = missingSyntax "XStmtLR"
      go (BindStmt _ p e _ _) =
#endif
        let bs = collectPatBinders p
            env' = foldr extendAlphaEnvInternal env bs
            vs' = vs `exceptQ` bs
        in m { smBindStmt = mAlter env vs p
                              (toA (mAlter env' vs' e f)) (smBindStmt m) }
      go LetStmt{} = missingSyntax "LetStmt"
      go ParStmt{} = missingSyntax "ParStmt"
      go TransStmt{} = missingSyntax "TransStmt"
      go RecStmt{} = missingSyntax "RecStmt"
      go ApplicativeStmt{} = missingSyntax "ApplicativeStmt"

  mMatch :: MatchEnv -> Key SMap -> (Substitution, SMap a) -> [(Substitution, a)]
  mMatch _   _   (_,SMEmpty) = []
  mMatch env s   (hs,m) = go (unLoc s) (hs,m)
    where
#if __GLASGOW_HASKELL__ < 806
      go (BodyStmt e _ _ _) = mapFor smBodyStmt >=> mMatch env e
      go (LastStmt e _ _) = mapFor smLastStmt >=> mMatch env e
      go (BindStmt p e _ _ _) =
#else
      go (BodyStmt _ e _ _) = mapFor smBodyStmt >=> mMatch env e
      go (LastStmt _ e _ _) = mapFor smLastStmt >=> mMatch env e
      go (BindStmt _ p e _ _) =
#endif
        let bs = collectPatBinders p
            env' = extendMatchEnv env bs
        in mapFor smBindStmt >=> mMatch env p >=> mMatch env' e
      go _ = const [] -- TODO

------------------------------------------------------------------------

data TyMap a
  = TyEmpty
  | TM { tyHole    :: Map RdrName a -- See Note [Holes]
       , tyHsTyVar :: VMap a
       , tyHsAppTy :: TyMap (TyMap a)
#if __GLASGOW_HASKELL__ < 806
       , tyHsAppsTy :: ListMap AppTyMap a
#endif
#if __GLASGOW_HASKELL__ < 810
       , tyHsForAllTy :: ForAllTyMap a -- See Note [Telescope]
#else
       , tyHsForAllTy :: ForallVisMap (ForAllTyMap a) -- See Note [Telescope]
#endif
       , tyHsFunTy :: TyMap (TyMap a)
       , tyHsListTy :: TyMap a
       , tyHsParTy :: TyMap a
       , tyHsQualTy :: TyMap (ListMap TyMap a)
       , tyHsSumTy :: ListMap TyMap a
       , tyHsTupleTy :: TupleSortMap (ListMap TyMap a)
         -- TODO: the rest
       }
  deriving (Functor)

emptyTyMapWrapper :: TyMap a
emptyTyMapWrapper = TM
  mEmpty mEmpty mEmpty
#if __GLASGOW_HASKELL__ < 806
  mEmpty
#endif
  mEmpty mEmpty mEmpty mEmpty mEmpty mEmpty mEmpty

instance PatternMap TyMap where
  type Key TyMap = LHsType GhcPs

  mEmpty :: TyMap a
  mEmpty = TyEmpty

  mUnion :: TyMap a -> TyMap a -> TyMap a
  mUnion TyEmpty m = m
  mUnion m TyEmpty = m
  mUnion m1 m2 = TM
    { tyHole = unionOn tyHole m1 m2
    , tyHsTyVar = unionOn tyHsTyVar m1 m2
    , tyHsAppTy = unionOn tyHsAppTy m1 m2
#if __GLASGOW_HASKELL__ < 806
    , tyHsAppsTy = unionOn tyHsAppsTy m1 m2
#endif
    , tyHsForAllTy = unionOn tyHsForAllTy m1 m2
    , tyHsFunTy = unionOn tyHsFunTy m1 m2
    , tyHsListTy = unionOn tyHsListTy m1 m2
    , tyHsParTy = unionOn tyHsParTy m1 m2
    , tyHsQualTy = unionOn tyHsQualTy m1 m2
    , tyHsSumTy = unionOn tyHsSumTy m1 m2
    , tyHsTupleTy = unionOn tyHsTupleTy m1 m2
    }

  mAlter :: AlphaEnv -> Quantifiers -> Key TyMap -> A a -> TyMap a -> TyMap a
  mAlter env vs ty f TyEmpty = mAlter env vs ty f emptyTyMapWrapper
#if __GLASGOW_HASKELL__ < 806
  mAlter env vs (tyLookThrough -> ty) f m@(TM {}) =
#else
  mAlter env vs ty f m@(TM {}) =
#endif
    go (unLoc ty) -- See Note [TyVar Quantifiers]
    where
#if __GLASGOW_HASKELL__ < 806
      go (HsTyVar _ (L _ v))
#else
      go (HsTyVar _ _ (L _ v))
#endif
        | v `isQ` vs = m { tyHole    = mAlter env vs v f (tyHole m) }
        | otherwise  = m { tyHsTyVar = mAlter env vs v f (tyHsTyVar m) }
      go HsOpTy{} = missingSyntax "HsOpTy"
      go HsIParamTy{} = missingSyntax "HsIParamTy"
      go HsKindSig{} = missingSyntax "HsKindSig"
      go HsSpliceTy{} = missingSyntax "HsSpliceTy"
      go HsDocTy{} = missingSyntax "HsDocTy"
      go HsBangTy{} = missingSyntax "HsBangTy"
      go HsRecTy{} = missingSyntax "HsRecTy"
#if __GLASGOW_HASKELL__ < 806
      go (HsAppsTy atys) = m { tyHsAppsTy = mAlter env vs atys f (tyHsAppsTy m) }
      go (HsAppTy ty1 ty2) = m { tyHsAppTy = mAlter env vs ty1 (toA (mAlter env vs ty2 f)) (tyHsAppTy m) }
      go (HsCoreTy _) = missingSyntax "HsCoreTy"
      go (HsEqTy _ _) = missingSyntax "HsEqTy"
      go (HsForAllTy bndrs ty') = m { tyHsForAllTy = mAlter env vs (bndrs, ty') f (tyHsForAllTy m) }
      go (HsFunTy ty1 ty2) = m { tyHsFunTy = mAlter env vs ty1 (toA (mAlter env vs ty2 f)) (tyHsFunTy m) }
      go (HsListTy ty') = m { tyHsListTy = mAlter env vs ty' f (tyHsListTy m) }
      go (HsParTy ty') = m { tyHsParTy = mAlter env vs ty' f (tyHsParTy m) }
      go (HsPArrTy _) = missingSyntax "HsPArrTy"
      go (HsQualTy (L _ cons) ty') =
        m { tyHsQualTy = mAlter env vs ty' (toA (mAlter env vs cons f)) (tyHsQualTy m) }
      go (HsSumTy tys) = m { tyHsSumTy = mAlter env vs tys f (tyHsSumTy m) }
      go (HsTupleTy ts tys) =
        m { tyHsTupleTy = mAlter env vs ts (toA (mAlter env vs tys f)) (tyHsTupleTy m) }
#else
      go (HsAppTy _ ty1 ty2) = m { tyHsAppTy = mAlter env vs ty1 (toA (mAlter env vs ty2 f)) (tyHsAppTy m) }
#if __GLASGOW_HASKELL__ < 810
      go (HsForAllTy _ bndrs ty') = m { tyHsForAllTy = mAlter env vs (bndrs, ty') f (tyHsForAllTy m) }
#else
      go (HsForAllTy _ vis bndrs ty') =
        m { tyHsForAllTy = mAlter env vs vis (toA (mAlter env vs (bndrs, ty') f)) (tyHsForAllTy m) }
#endif
      go (HsFunTy _ ty1 ty2) = m { tyHsFunTy = mAlter env vs ty1 (toA (mAlter env vs ty2 f)) (tyHsFunTy m) }
      go (HsListTy _ ty') = m { tyHsListTy = mAlter env vs ty' f (tyHsListTy m) }
      go (HsParTy _ ty') = m { tyHsParTy = mAlter env vs ty' f (tyHsParTy m) }
      go (HsQualTy _ (L _ cons) ty') =
        m { tyHsQualTy = mAlter env vs ty' (toA (mAlter env vs cons f)) (tyHsQualTy m) }
      go HsStarTy{} = missingSyntax "HsStarTy"
      go (HsSumTy _ tys) = m { tyHsSumTy = mAlter env vs tys f (tyHsSumTy m) }
      go (HsTupleTy _ ts tys) =
        m { tyHsTupleTy = mAlter env vs ts (toA (mAlter env vs tys f)) (tyHsTupleTy m) }
      go XHsType{} = missingSyntax "XHsType"
#endif
      go HsExplicitListTy{} = missingSyntax "HsExplicitListTy"
      go HsExplicitTupleTy{} = missingSyntax "HsExplicitTupleTy"
      go HsTyLit{} = missingSyntax "HsTyLit"
      go HsWildCardTy{} = missingSyntax "HsWildCardTy"
#if __GLASGOW_HASKELL__ < 808
#else
      go HsAppKindTy{} = missingSyntax "HsAppKindTy"
#endif

  mMatch :: MatchEnv -> Key TyMap -> (Substitution, TyMap a) -> [(Substitution, a)]
  mMatch _   _  (_,TyEmpty) = []
#if __GLASGOW_HASKELL__ < 806
  mMatch env (tyLookThrough -> ty) (hs,m@TM{}) =
#else
  mMatch env ty (hs,m@TM{}) =
#endif
    hss ++ go (unLoc ty) (hs,m) -- See Note [TyVar Quantifiers]
    where
      hss = extendResult (tyHole m) (HoleType $ mePruneA env ty) hs

#if __GLASGOW_HASKELL__ < 806
      go (HsAppTy ty1 ty2) = mapFor tyHsAppTy >=> mMatch env ty1 >=> mMatch env ty2
      go (HsAppsTy atys) = mapFor tyHsAppsTy >=> mMatch env atys
      go (HsForAllTy bndrs ty') = mapFor tyHsForAllTy >=> mMatch env (bndrs, ty')
      go (HsFunTy ty1 ty2) = mapFor tyHsFunTy >=> mMatch env ty1 >=> mMatch env ty2
      go (HsListTy ty') = mapFor tyHsListTy >=> mMatch env ty'
      go (HsParTy ty') = mapFor tyHsParTy >=> mMatch env ty'
      go (HsQualTy (L _ cons) ty') = mapFor tyHsQualTy >=> mMatch env ty' >=> mMatch env cons
      go (HsSumTy tys) = mapFor tyHsSumTy >=> mMatch env tys
      go (HsTupleTy ts tys) = mapFor tyHsTupleTy >=> mMatch env ts >=> mMatch env tys
      go (HsTyVar _ v) = mapFor tyHsTyVar >=> mMatch env (unLoc v)
#else
      go (HsAppTy _ ty1 ty2) = mapFor tyHsAppTy >=> mMatch env ty1 >=> mMatch env ty2
#if __GLASGOW_HASKELL__ < 810
      go (HsForAllTy _ bndrs ty') = mapFor tyHsForAllTy >=> mMatch env (bndrs, ty')
#else
      go (HsForAllTy _ vis bndrs ty') =
        mapFor tyHsForAllTy >=> mMatch env vis >=> mMatch env (bndrs, ty')
#endif
      go (HsFunTy _ ty1 ty2) = mapFor tyHsFunTy >=> mMatch env ty1 >=> mMatch env ty2
      go (HsListTy _ ty') = mapFor tyHsListTy >=> mMatch env ty'
      go (HsParTy _ ty') = mapFor tyHsParTy >=> mMatch env ty'
      go (HsQualTy _ (L _ cons) ty') = mapFor tyHsQualTy >=> mMatch env ty' >=> mMatch env cons
      go (HsSumTy _ tys) = mapFor tyHsSumTy >=> mMatch env tys
      go (HsTupleTy _ ts tys) = mapFor tyHsTupleTy >=> mMatch env ts >=> mMatch env tys
      go (HsTyVar _ _ v) = mapFor tyHsTyVar >=> mMatch env (unLoc v)
#endif
      go _                  = const [] -- TODO

#if __GLASGOW_HASKELL__ < 806
-- Note [TyVar Quantifiers]
--
-- GHC parses a tycon app as a list of types (Maybe Int becomes [Maybe, Int]).
-- A nullary tycon app becomes a singleton list, and a tyvar is treated as a
-- a nullary tycon. Quantifiers are tyvars, so they'll be rigidly buried in
-- singleton lists, meaning 'a' cannot match with 'Maybe Int' because [a]
-- will not unify with [Maybe, Int]. Singleton tycons suffer the same problem.
-- [Foo] will not match with [Maybe, Foo] when unfolding Foo. To solve this,
-- we 'look through' such singleton lists.

tyLookThrough :: Key TyMap -> Key TyMap
tyLookThrough (L _ (HsAppsTy [L _ (HsAppPrefix ty)])) = ty
tyLookThrough ty = ty

------------------------------------------------------------------------

data AppTyMap a
  = AppTyEmpty
  | ATM { atmAppInfix :: VMap a
        , atmAppPrefix :: TyMap a
        }
  deriving (Functor)

emptyAppTyMapWrapper :: AppTyMap a
emptyAppTyMapWrapper = ATM mEmpty mEmpty

instance PatternMap AppTyMap where
  type Key AppTyMap = LHsAppType GhcPs

  mEmpty :: AppTyMap a
  mEmpty = AppTyEmpty

  mUnion :: AppTyMap a -> AppTyMap a -> AppTyMap a
  mUnion AppTyEmpty m = m
  mUnion m AppTyEmpty = m
  mUnion m1 m2 = ATM
    { atmAppInfix = unionOn atmAppInfix m1 m2
    , atmAppPrefix = unionOn atmAppPrefix m1 m2
    }

  mAlter :: AlphaEnv -> Quantifiers -> Key AppTyMap -> A a -> AppTyMap a -> AppTyMap a
  mAlter env vs aty f AppTyEmpty = mAlter env vs aty f emptyAppTyMapWrapper
  mAlter env vs aty f m@(ATM {}) = go (unLoc aty)
    where
      go (HsAppInfix r) = m { atmAppInfix = mAlter env vs (unLoc r) f (atmAppInfix m) }
      go (HsAppPrefix ty) = m { atmAppPrefix = mAlter env vs ty f (atmAppPrefix m) }

  mMatch :: MatchEnv -> Key AppTyMap -> (Substitution, AppTyMap a) -> [(Substitution, a)]
  mMatch _   _  (_,AppTyEmpty) = []
  mMatch env aty (hs,m@ATM{})  = go (unLoc aty) (hs,m)
    where
      go (HsAppInfix r)   = mapFor atmAppInfix >=> mMatch env (unLoc r)
      go (HsAppPrefix ty) = mapFor atmAppPrefix >=> mMatch env ty
#endif

------------------------------------------------------------------------

newtype RFMap a = RFM { rfmField :: VMap (EMap a) }
  deriving (Functor)

instance PatternMap RFMap where
  type Key RFMap = LHsRecField' RdrName (LHsExpr GhcPs)

  mEmpty :: RFMap a
  mEmpty = RFM mEmpty

  mUnion :: RFMap a -> RFMap a -> RFMap a
  mUnion (RFM m1) (RFM m2) = RFM (mUnion m1 m2)

  mAlter :: AlphaEnv -> Quantifiers -> Key RFMap -> A a -> RFMap a -> RFMap a
  mAlter env vs lf f m = go (unLoc lf)
    where
      go (HsRecField lbl arg _pun) =
        m { rfmField = mAlter env vs (unLoc lbl) (toA (mAlter env vs arg f)) (rfmField m) }

  mMatch :: MatchEnv -> Key RFMap -> (Substitution, RFMap a) -> [(Substitution, a)]
  mMatch env lf (hs,m) = go (unLoc lf) (hs,m)
    where
      go (HsRecField lbl arg _pun) =
        mapFor rfmField >=> mMatch env (unLoc lbl) >=> mMatch env arg

-- Helper class to collapse the complex encoding of record fields into RdrNames.
-- (The complexity is to support punning/duplicate/overlapping fields, which
-- all happens well after parsing, so is not needed here.)
class RecordFieldToRdrName f where
  recordFieldToRdrName :: f -> RdrName

#if __GLASGOW_HASKELL__ < 806
instance RecordFieldToRdrName (AmbiguousFieldOcc p) where
#else
instance RecordFieldToRdrName (AmbiguousFieldOcc GhcPs) where
#endif
  recordFieldToRdrName = rdrNameAmbiguousFieldOcc

instance RecordFieldToRdrName (FieldOcc p) where
  recordFieldToRdrName = unLoc . rdrNameFieldOcc

fieldsToRdrNames
  :: RecordFieldToRdrName f
  => [LHsRecField' f arg]
  -> [LHsRecField' RdrName arg]
fieldsToRdrNames = map go
  where
    go (L l (HsRecField (L l2 f) arg pun)) =
      L l (HsRecField (L l2 (recordFieldToRdrName f)) arg pun)

------------------------------------------------------------------------

data TupleSortMap a = TupleSortMap
  { tsUnboxed :: MaybeMap a
  , tsBoxed :: MaybeMap a
  , tsConstraint :: MaybeMap a
  , tsBoxedOrConstraint :: MaybeMap a
  }
  deriving (Functor)

instance PatternMap TupleSortMap where
  type Key TupleSortMap = HsTupleSort

  mEmpty :: TupleSortMap a
  mEmpty = TupleSortMap mEmpty mEmpty mEmpty mEmpty

  mUnion :: TupleSortMap a -> TupleSortMap a -> TupleSortMap a
  mUnion m1 m2 = TupleSortMap
    { tsUnboxed = unionOn tsUnboxed m1 m2
    , tsBoxed = unionOn tsBoxed m1 m2
    , tsConstraint = unionOn tsConstraint m1 m2
    , tsBoxedOrConstraint = unionOn tsBoxedOrConstraint m1 m2
    }

  mAlter :: AlphaEnv -> Quantifiers -> Key TupleSortMap -> A a -> TupleSortMap a -> TupleSortMap a
  mAlter env vs HsUnboxedTuple f m =
    m { tsUnboxed = mAlter env vs () f (tsUnboxed m) }
  mAlter env vs HsBoxedTuple f m =
    m { tsBoxed = mAlter env vs () f (tsBoxed m) }
  mAlter env vs HsConstraintTuple f m =
    m { tsConstraint = mAlter env vs () f (tsConstraint m) }
  mAlter env vs HsBoxedOrConstraintTuple f m =
    m { tsBoxedOrConstraint = mAlter env vs () f (tsBoxedOrConstraint m) }

  mMatch :: MatchEnv -> Key TupleSortMap -> (Substitution, TupleSortMap a) -> [(Substitution, a)]
  mMatch env HsUnboxedTuple = mapFor tsUnboxed >=> mMatch env ()
  mMatch env HsBoxedTuple = mapFor tsBoxed >=> mMatch env ()
  mMatch env HsConstraintTuple = mapFor tsConstraint >=> mMatch env ()
  mMatch env HsBoxedOrConstraintTuple = mapFor tsBoxedOrConstraint >=> mMatch env ()

------------------------------------------------------------------------

-- Note [Telescope]
-- Haskell's forall quantification is a telescope (type binders are in-scope
-- to binders to the right. Example: forall r (a :: TYPE r). ...
--
-- To support this, we peel off the binders one at a time, extending the
-- environment at each layer.

data ForAllTyMap a = ForAllTyMap
  { fatNil :: TyMap a
  , fatUser :: ForAllTyMap a
  , fatKinded :: TyMap (ForAllTyMap a)
  }
  deriving (Functor)

instance PatternMap ForAllTyMap where
  type Key ForAllTyMap = ([LHsTyVarBndr GhcPs], LHsType GhcPs)

  mEmpty :: ForAllTyMap a
  mEmpty = ForAllTyMap mEmpty mEmpty mEmpty

  mUnion :: ForAllTyMap a -> ForAllTyMap a -> ForAllTyMap a
  mUnion m1 m2 = ForAllTyMap
    { fatNil = unionOn fatNil m1 m2
    , fatUser = unionOn fatUser m1 m2
    , fatKinded = unionOn fatKinded m1 m2
    }

  mAlter :: AlphaEnv -> Quantifiers -> Key ForAllTyMap -> A a -> ForAllTyMap a -> ForAllTyMap a
  mAlter env vs ([], ty) f m = m { fatNil = mAlter env vs ty f (fatNil m) }
#if __GLASGOW_HASKELL__ < 806
  mAlter env vs (L _ (UserTyVar (L _ v)):rest, ty) f m =
#else
  mAlter env vs (L _ (UserTyVar _ (L _ v)):rest, ty) f m =
#endif
    let
      env' = extendAlphaEnvInternal v env
      vs' = vs `exceptQ` [v]
    in m { fatUser = mAlter env' vs' (rest, ty) f (fatUser m) }
#if __GLASGOW_HASKELL__ < 806
  mAlter env vs (L _ (KindedTyVar (L _ v) k):rest, ty) f m =
#else
  mAlter _ _ (L _ (XTyVarBndr _):_,_) _ _ = missingSyntax "XTyVarBndr"
  mAlter env vs (L _ (KindedTyVar _ (L _ v) k):rest, ty) f m =
#endif
    let
      env' = extendAlphaEnvInternal v env
      vs' = vs `exceptQ` [v]
    in m { fatKinded  = mAlter env vs k (toA (mAlter env' vs' (rest, ty) f)) (fatKinded m) }

  mMatch :: MatchEnv -> Key ForAllTyMap -> (Substitution, ForAllTyMap a) -> [(Substitution, a)]
  mMatch env ([],ty) = mapFor fatNil >=> mMatch env ty
#if __GLASGOW_HASKELL__ < 806
  mMatch env (L _ (UserTyVar (L _ v)):rest, ty) =
#else
  mMatch env (L _ (UserTyVar _ (L _ v)):rest, ty) =
#endif
    let env' = extendMatchEnv env [v]
    in mapFor fatUser >=> mMatch env' (rest, ty)
#if __GLASGOW_HASKELL__ < 806
  mMatch env (L _ (KindedTyVar (L _ v) k):rest, ty) =
#else
  mMatch _ (L _ (XTyVarBndr _):_,_) = const []
  mMatch env (L _ (KindedTyVar _ (L _ v) k):rest, ty) =
#endif
    let env' = extendMatchEnv env [v]
    in mapFor fatKinded >=> mMatch env k >=> mMatch env' (rest, ty)

#if __GLASGOW_HASKELL__ < 810
#else
data ForallVisMap a = ForallVisMap
  { favVis :: MaybeMap a
  , favInvis :: MaybeMap a
  }
  deriving (Functor)

instance PatternMap ForallVisMap where
  type Key ForallVisMap = ForallVisFlag

  mEmpty :: ForallVisMap a
  mEmpty = ForallVisMap mEmpty mEmpty

  mUnion :: ForallVisMap a -> ForallVisMap a -> ForallVisMap a
  mUnion m1 m2 = ForallVisMap
    { favVis = unionOn favVis m1 m2
    , favInvis = unionOn favInvis m1 m2
    }

  mAlter :: AlphaEnv -> Quantifiers -> Key ForallVisMap -> A a -> ForallVisMap a -> ForallVisMap a
  mAlter env vs ForallVis f m =
    m { favVis = mAlter env vs () f (favVis m) }
  mAlter env vs ForallInvis f m =
    m { favInvis = mAlter env vs () f (favInvis m) }

  mMatch :: MatchEnv -> Key ForallVisMap -> (Substitution, ForallVisMap a) -> [(Substitution, a)]
  mMatch env ForallVis = mapFor favVis >=> mMatch env ()
  mMatch env ForallInvis = mapFor favInvis >=> mMatch env ()
#endif
