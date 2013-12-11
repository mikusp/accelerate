{-# LANGUAGE CPP                  #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns         #-}
{-# LANGUAGE PatternGuards        #-}
{-# LANGUAGE DeriveDataTypeable   #-}
{-# LANGUAGE ImpredicativeTypes   #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE TupleSections        #-}
-- |
-- Module      : Data.Array.Accelerate.Trafo.Vectorise
-- Copyright   : [2012..2013] Manuel M T Chakravarty, Gabriele Keller, Trevor L. McDonell, Robert Clifton-Everest
-- License     : BSD3
--
-- Maintainer  : Robert Clifton-Everest <robertce@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--
-- Performs Blelloch's flattening transform.
--

module Data.Array.Accelerate.Trafo.Vectorise (

  vectoriseAcc,
  vectoriseAfun,

) where

import Prelude                                          hiding ( exp, replicate )
import qualified Prelude                                as P
import Data.Typeable
import Control.Applicative                              hiding ( Const )

-- friends
import Data.Array.Accelerate.AST
import Data.Array.Accelerate.Type
import Data.Array.Accelerate.Tuple
import Data.Array.Accelerate.Array.Sugar
import Data.Array.Accelerate.Trafo.Base
import Data.Array.Accelerate.Trafo.Substitution

import qualified Data.Array.Accelerate.Debug            as Stats

#include "accelerate.h"

-- |Encodes the relationship between the old environments and the new environments during the
-- lifting transform
--
data Context env aenv env' aenv' where
  -- All environments are empty
  EmptyC     :: Context () () () ()

  -- An expression that has already been lifted
  PushLExpC :: (Shape sh, Elt e)
            => Context env aenv env' aenv'
            -> sh {- dummy -}
            -> Context (env, e) aenv env' (aenv', Array sh e)

  -- An unlifted expression
  PushExpC  :: Elt e
            => Context env aenv env' aenv'
            -> Context (env, e) aenv (env',e) aenv'

  -- An array expression
  PushAccC  :: Arrays t
            => Context env aenv env' aenv'
            -> Context env (aenv, t) env' (aenv', t)

type VectoriseAcc acc = forall env env' aenv aenv' t.
                        Context env aenv env' aenv'
                     -> acc env  aenv t
                     -> acc env' aenv' t

-- |Vectorise a closed array expression.
--
vectoriseAcc :: Acc t
             -> Acc t
vectoriseAcc = vectoriseOpenAcc EmptyC

-- |Vectorise a closed array function
vectoriseAfun :: Afun t
              -> Afun t
vectoriseAfun = vectoriseOpenAfun EmptyC

-- |Given a lifting context for the free variables, vectorise an open array expression.
vectoriseOpenAcc :: Context env aenv env' aenv'
                 -> OpenAcc env  aenv t
                 -> OpenAcc env' aenv' t
vectoriseOpenAcc ctx (OpenAcc a) = OpenAcc $ vectorisePreOpenAcc vectoriseOpenAcc ctx a

-- |Given a lifting context for the free variables, vectorise an open array expression.
vectoriseOpenAfun :: Context env aenv env' aenv'
                  -> OpenAfun env  aenv  t
                  -> OpenAfun env' aenv' t
vectoriseOpenAfun = vectorisePreOpenAfun vectoriseOpenAcc

vectorisePreOpenAfun :: VectoriseAcc acc
                     -> Context env aenv env' aenv'
                     -> PreOpenAfun acc env  aenv  t
                     -> PreOpenAfun acc env' aenv' t
vectorisePreOpenAfun k ctx (Abody f) = Abody $ k ctx f
vectorisePreOpenAfun k ctx (Alam f)  = Alam $ vectorisePreOpenAfun k (PushAccC ctx) f

vectorisePreOpenAcc :: forall acc env env' aenv aenv' t. Kit acc
                    => VectoriseAcc acc
                    -> Context env aenv env' aenv'
                    -> PreOpenAcc acc env  aenv t
                    -> PreOpenAcc acc env' aenv' t
vectorisePreOpenAcc vectAcc ctx exp
  = case exp of
    Alet a b            -> aletV a b
    Elet e a            -> eletV e a
    Avar ix             -> avarV ix
    Atuple tup          -> Atuple (cvtT tup)
    Aprj tup a          -> Aprj tup (cvtA a)
    Apply f a           -> Apply (cvtAfun f) (cvtA a)
    Aforeign ff afun as -> Aforeign ff afun (cvtA as)
    Acond p t e         -> acondV (cvtE' p) (cvtA t) (cvtA e)
    Awhile p it i       -> Awhile (cvtAfun p) (cvtAfun it) (cvtA i)
    Use a               -> Use a
    Unit e              -> Alet (cvtE' e) (inject $ Unit topEA)
    Reshape e a         -> Alet (cvtE' e) (inject $ Reshape topEA (weakenATop (cvtA a)))
    Generate e f        -> generateV (cvtE' e) (cvtF1 f)
    -- Transform only appears as part of subsequent optimsations.
    Transform _ _ _ _   -> INTERNAL_ERROR(error) "vectorisePreOpenAcc" "Unable to vectorise Transform"
    Replicate sl slix a -> Alet (cvtE' slix) (inject $ Replicate sl topEA (weakenATop (cvtA a)))
    Slice sl a slix     -> Alet (cvtE' slix) (inject $ Slice sl (weakenATop (cvtA a)) topEA)
    Map f a             -> cvtF1 f `subApply` cvtA a
    ZipWith f a1 a2     -> zipWithV f (cvtA a1) (cvtA a2)
    Fold f z a          -> cvtFEA Fold f z a
    Fold1 f a           -> cvtFA Fold1 f a
    FoldSeg f z a s     -> cvtFEAA FoldSeg f z a s
    Fold1Seg f a s      -> cvtFAA Fold1Seg f a s
    Scanl f z a         -> cvtFEA Scanl f z a
    Scanl' f z a        -> cvtFEA Scanl' f z a
    Scanl1 f a          -> cvtFA Scanl1 f a
    Scanr f z a         -> cvtFEA Scanr f z a
    Scanr' f z a        -> cvtFEA Scanr' f z a
    Scanr1 f a          -> cvtFA Scanr1 f a
    Permute f1 a1 f2 a2 -> permuteV f1 (cvtA a1) (cvtF1 f2) (cvtA a2)
    Backpermute sh f a  -> backpermuteV (cvtE' sh) (cvtF1 f) (cvtA a)
    Stencil f b a       -> cvtFA (`Stencil` b) f a
    Stencil2 f b1 a1 b2 a2
                        -> stencil2V f b1 a1 b2 a2

  where
    nestedError :: String -> String
    nestedError ctx = "Unexpect nested parallelism " ++ ctx

    cvtA :: forall t. acc env aenv t -> acc env' aenv' t
    cvtA = vectAcc ctx

    cvtE :: forall e sh. Shape sh
         => PreOpenExp acc env aenv e
         -> acc (env',sh) aenv' (Array sh e)
    cvtE = inject . liftExp vectAcc ctx

    cvtE' :: forall e. Elt e
          => PreOpenExp acc env aenv e
          -> acc env' aenv' (Array Z e)
    cvtE' exp = inlineE (cvtE exp) (Const ())

    cvtT :: forall t.
            Atuple (acc env aenv) t
         -> Atuple (acc env' aenv') t
    cvtT NilAtup        = NilAtup
    cvtT (SnocAtup t a) = SnocAtup (cvtT t) (cvtA a)

    cvtAfun :: forall f.
               PreOpenAfun acc env aenv f
            -> PreOpenAfun acc env' aenv' f
    cvtAfun = vectorisePreOpenAfun vectAcc ctx

    cvtF1 :: forall a b sh. Shape sh
          => PreOpenFun  acc env  aenv  (a -> b)
          -> PreOpenAfun acc env' aenv' (Array sh a -> Array sh b)
    cvtF1 (Lam (Body f)) = Alam $ Abody (inlineE f' (Shape (inject $ Avar ZeroIdx)))
      where
        f' = inject $ liftExp vectAcc (PushLExpC ctx (undefined :: sh)) f
    cvtF1 _              = error "Inconsistent valuation"

    -- Vectorised versions of combinators.
    -- ===================================

    zipWithV :: forall a b c sh. Shape sh
             => PreOpenFun acc env aenv  (a -> b -> c)
             -> acc            env'  aenv' (Array sh a)
             -> acc            env'  aenv' (Array sh b)
             -> PreOpenAcc acc env'  aenv' (Array sh c)
    zipWithV (Lam (Lam (Body f))) a b = (Alet a . inject . Alet b') (inlineE f' sh)
      where
        f' :: acc (env',sh) ((aenv', Array sh a), Array sh b) (Array sh c)
        f' = inject $ liftExp vectAcc (PushLExpC (PushLExpC ctx (undefined :: sh)) (undefined :: sh)) f

        sh :: PreOpenExp acc env' ((aenv', Array sh a), Array sh b) sh
        sh = Intersect (Shape (inject $ Avar ZeroIdx)) (Shape (inject $ Avar $ SuccIdx ZeroIdx))

        b' :: acc env' (aenv', Array sh a) (Array sh b)
        b' = weakenATop b
    zipWithV _                    _ _ = error "Inconsistent valuation"

    aletV :: (Arrays bnd, Arrays t) => acc env aenv bnd -> acc env (aenv, bnd) t -> PreOpenAcc acc env' aenv' t
    aletV bnd body = Alet (vectAcc ctx bnd) (vectAcc (PushAccC ctx) body)

    eletV :: forall bnd body. (Elt bnd, Arrays body) => PreOpenExp acc env aenv bnd -> acc (env, bnd) aenv body -> PreOpenAcc acc env' aenv' body
    eletV bnd body = Alet bnd' $ inject $ Elet (Index (inject $ Avar ZeroIdx) IndexNil) (weakenATop $ vectAcc (PushExpC ctx) body)
      where
        bnd' :: acc env' aenv' (Array Z bnd)
        bnd' = inlineE (cvtE bnd) (Const ())

    avarV :: Arrays t
          => Idx aenv t
          -> PreOpenAcc acc env' aenv' t
    avarV = Avar . cvtIx ctx
      where
        cvtIx :: forall env aenv env' aenv'. Context env aenv env' aenv' -> Idx aenv t -> Idx aenv' t
        cvtIx (PushLExpC d _) ix           = SuccIdx (cvtIx d ix)
        cvtIx (PushExpC d)    ix           = cvtIx d ix
        cvtIx (PushAccC _)    ZeroIdx      = ZeroIdx
        cvtIx (PushAccC d)    (SuccIdx ix) = SuccIdx (cvtIx d ix)
        cvtIx _               _            = INTERNAL_ERROR(error) "liftExp" "Inconsistent valuation"

    acondV :: Arrays t
           => acc env' aenv' (Array Z Bool)
           -> acc env' aenv' t
           -> acc env' aenv' t
           -> PreOpenAcc acc env' aenv' t
    acondV p t e = Alet p (inject $ Acond topEA (weakenATop t) (weakenATop e))

    generateV :: forall sh e. (Elt e, Shape sh)
              => acc env' aenv' (Array Z sh)
              -> PreOpenAfun acc env' aenv' (Array sh sh -> Array sh e)
              -> PreOpenAcc  acc env' aenv' (Array sh e)
    generateV e f = f `subApply` inject (Alet e gen)
      where
        gen :: acc env' (aenv', Array Z sh) (Array sh sh)
        gen = inject $ Generate topEA (Lam (Body (Var ZeroIdx)))

    backpermuteV :: (Shape sh, Shape sh', Elt e)
                 => acc env' aenv' (Scalar sh')
                 -> PreOpenAfun acc env' aenv' (Array sh' sh' -> Array sh' sh)
                 -> acc env' aenv' (Array sh e)
                 -> PreOpenAcc acc env' aenv' (Array sh' e)
    backpermuteV sh f a = Alet sh
                        $ inject
                        $ Alet (inject $ weakenATop f `subApply` inject (extentArray topEA))
                        $ inject
                        $ Backpermute (weakenATop topEA) g (weakenATop2 a)
      where
        g = Lam $ Body $ Index (inject $ Avar ZeroIdx) $ Var ZeroIdx

    permuteV :: (Shape sh, Shape sh', Elt e)
             => PreOpenFun acc env aenv (e -> e -> e)
             -> acc env' aenv' (Array sh' e)
             -> PreOpenAfun acc env' aenv' (Array sh sh -> Array sh sh')
             -> acc env' aenv' (Array sh e)
             -> PreOpenAcc acc env' aenv' (Array sh' e)
    permuteV f1 a1 f2 a2 | Avoided (env, f1') <- avoidF f1
                         = bind env
                         $ Alet (sink env a2)
                         $ inject
                         $ Alet (inject $ weakenATop (sink env f2) `subApply` inject (extentArray (Shape (inject $ Avar ZeroIdx))))
                         $ inject
                         $ Permute (weakenATop2 f1')
                                   (weakenATop2 $ sink env a1)
                                   (Lam $ Body $ Index (inject $ Avar ZeroIdx) $ Var ZeroIdx)
                                   (inject $ Avar $ SuccIdx ZeroIdx)
                         | otherwise
                         = INTERNAL_ERROR(error) "vectorisePreOpenAcc" (nestedError "in first argument to Permute")

    stencil2V :: (Elt e', Stencil sh e2 stencil2, Stencil sh e1 stencil1)
              => PreOpenFun acc env aenv (stencil1 ->
                                          stencil2 -> e')
              -> Boundary                (EltRepr e1)
              -> acc            env aenv (Array sh e1)
              -> Boundary                (EltRepr e2)
              -> acc            env aenv (Array sh e2)
              -> PreOpenAcc acc env' aenv' (Array sh e')
    stencil2V (avoidF -> Avoided (env, f)) b1 a1 b2 a2
      = bind env $ Stencil2 f b1 (sink env $ cvtA a1) b2 (sink env $ cvtA a2)
    stencil2V _                                 _  _  _  _
      = INTERNAL_ERROR(error) "vectorisePreOpenAcc" (nestedError "in first argument to Stencil")

    cvtFEA :: forall e f a1 a2. (Elt e, Arrays a1, Arrays a2)
           => (forall env aenv. PreOpenFun acc env aenv f -> PreOpenExp acc env aenv e -> acc env aenv a1 -> PreOpenAcc acc env aenv a2)
           -> PreOpenFun acc env  aenv  f
           -> PreOpenExp acc env  aenv  e
           -> acc            env  aenv  a1
           -> PreOpenAcc acc env' aenv' a2
    cvtFEA wrap
           (avoidF -> Avoided (env, f))
           (cvtE'  -> z)
           (cvtA   -> a)
      = bind env $ Alet (sink env z) $ inject $ wrap (weakenATop f) topEA (weakenATop $ sink env a)
    cvtFEA wrap _ _ _ = INTERNAL_ERROR(error) "vectorisePreOpenAcc"
                                              (nestedError $ "in first argument to " ++ showPreAccOp (wrap undefined undefined undefined))

    cvtFEAA :: forall e f a1 a2 a3. (Elt e, Arrays a1, Arrays a2, Arrays a3)
            => (forall env aenv. PreOpenFun acc env aenv f -> PreOpenExp acc env aenv e -> acc env aenv a1 -> acc env aenv a2 -> PreOpenAcc acc env aenv a3)
            -> PreOpenFun acc env  aenv  f
            -> PreOpenExp acc env  aenv  e
            -> acc            env  aenv  a1
            -> acc            env  aenv  a2
            -> PreOpenAcc acc env' aenv' a3
    cvtFEAA wrap
            (avoidF -> Avoided (env, f))
            (cvtE'  -> z)
            (cvtA   -> a)
            (cvtA   -> b)
      = bind env $ Alet (sink env z) $ inject $ wrap (weakenATop f) topEA (weakenATop $ sink env a) (weakenATop $ sink env b)
    cvtFEAA wrap _ _ _ _ = INTERNAL_ERROR(error) "vectorisePreOpenAcc"
                                                 (nestedError $ "in first argument to " ++ showPreAccOp (wrap undefined undefined undefined undefined))

    cvtFA :: forall f a1 a2. (Arrays a1, Arrays a2)
          => (forall env aenv. PreOpenFun acc env aenv f -> acc env aenv a1 -> PreOpenAcc acc env aenv a2)
          -> PreOpenFun acc env  aenv  f
          -> acc            env  aenv  a1
          -> PreOpenAcc acc env' aenv' a2
    cvtFA wrap
           (avoidF -> Avoided (env, f))
           (cvtA  -> a)
      = bind env $ wrap f (sink env a)
    cvtFA wrap _ _ = INTERNAL_ERROR(error) "vectorisePreOpenAcc"
                                           (nestedError $ "in first argument to " ++ showPreAccOp (wrap undefined undefined))

    cvtFAA :: forall f a1 a2 a3. (Arrays a1, Arrays a2, Arrays a3)
           => (forall env aenv. PreOpenFun acc env aenv f -> acc env aenv a1 -> acc env aenv a2 -> PreOpenAcc acc env aenv a3)
           -> PreOpenFun acc env  aenv  f
           -> acc            env  aenv  a1
           -> acc            env  aenv  a2
           -> PreOpenAcc acc env' aenv' a3
    cvtFAA wrap
           (avoidF -> Avoided (env, f))
           (cvtA   -> a)
           (cvtA   -> b)
      = bind env $ wrap f (sink env a) (sink env b)
    cvtFAA wrap _ _ _ = INTERNAL_ERROR(error) "vectorisePreOpenAcc"
                                           (nestedError $ "in first argument to " ++ showPreAccOp (wrap undefined undefined undefined))

    extentArray :: forall sh env aenv. Shape sh
                => PreOpenExp acc env aenv sh
                -> PreOpenAcc acc env aenv (Array sh sh)
    extentArray sh = Generate sh $ Lam $ Body $ Var ZeroIdx

    avoidF :: PreOpenFun acc env  aenv f
           -> AvoidFun acc env' aenv' f
    avoidF (avoidFun -> Avoided (env, f)) | ExtendContext d <- extendContext env ctx
                                               , Just f' <- rebuildToLift d f
                                               , env'    <- liftExtend vectAcc env ctx d
                                               = Avoided (env', f')
    avoidF _                                   = Unavoided

-- |Performs the lifting transform on a given scalar expression.
--
-- Because lifting is performed in the presence of higher dimensional arrays, the output of the
-- transform has an extra element in the environment, the shape of the output array.
liftExp :: forall acc env env' aenv aenv' sh e. (Kit acc, Shape sh)
        => VectoriseAcc acc
        -> Context env aenv env' aenv'
        -> PreOpenExp acc env       aenv  e
        -> PreOpenAcc acc (env',sh) aenv' (Array sh e)
liftExp vectAcc ctx exp
  = case exp of
      Let bnd body              -> letL bnd body
      Var ix                    -> varL ctx ix id id
      Const c                   -> replicate (Const c)
      Tuple tup                 -> liftTuple vectAcc ctx tup
      Prj ix t                  -> Map (fun1 (Prj ix)) (cvtE t)
      IndexNil                  -> replicate IndexNil
      IndexAny                  -> replicate IndexAny
      IndexCons sh sz           -> ZipWith (fun2 IndexCons) (cvtE sh) (cvtE sz)
      IndexHead sh              -> Map (fun1 IndexHead) (cvtE sh)
      IndexTail sh              -> Map (fun1 IndexTail) (cvtE sh)
      IndexSlice x ix sh        -> ZipWith (fun2 (IndexSlice x)) (cvtE ix) (cvtE sh)
      IndexFull x ix sl         -> ZipWith (fun2 (IndexFull x)) (cvtE ix) (cvtE sl)
      ToIndex sh ix             -> ZipWith (fun2 ToIndex) (cvtE sh) (cvtE ix)
      FromIndex sh ix           -> ZipWith (fun2 FromIndex) (cvtE sh) (cvtE ix)
      Cond p t e                -> condL p t e
      While p it i              -> whileL p it i
      PrimConst c               -> replicate (PrimConst c)
      PrimApp f x               -> Map (Lam (Body (PrimApp f (Var ZeroIdx)))) (cvtE x)
      Index a sh                -> indexL a sh
      LinearIndex a i           -> linearIndexL a i
      Shape a                   -> shapeL a
      ShapeSize sh              -> Map (fun1 ShapeSize) (cvtE sh)
      Intersect s t             -> ZipWith (fun2 Intersect) (cvtE s) (cvtE t)
      Foreign ff f e            -> Map (fun1 (Foreign ff f)) (cvtE e)
  where
    cvtE :: forall sh e. Shape sh
         => PreOpenExp acc env aenv e
         -> acc (env',sh) aenv' (Array sh e)
    cvtE exp' = inject $ liftExp vectAcc ctx exp'

    cvtA :: forall sh' e'. acc env aenv (Array sh' e')
         -> acc (env',sh) aenv' (Array sh' e')
    cvtA = weakenE SuccIdx . vectAcc ctx

    cvtF1 :: PreOpenFun acc env aenv (a -> b)
          -> PreOpenAfun acc (env',sh) aenv' (Array sh a -> Array sh b)
    cvtF1 (Lam (Body f)) = (Alam . Abody) (inject $ liftExp vectAcc (PushLExpC ctx (undefined::sh)) f)
    cvtF1 _              = error "Inconsistent valuation"

    replicate :: forall e. Elt e => PreOpenExp acc ((env', sh), sh) aenv' e -> PreOpenAcc acc (env',sh) aenv' (Array sh e)
    replicate c = Generate (Var ZeroIdx) (Lam (Body c))

    -- Lifted versions of operations
    -- ==============================

    varL :: forall env aenv env'' aenv''. (Elt e, Shape sh)
         => Context env aenv env'' aenv''
         -> Idx env e
         -> (forall e. Idx env''  e -> Idx env'  e)
         -> (forall a. Idx aenv'' a -> Idx aenv' a)
         -> PreOpenAcc acc (env',sh) aenv' (Array sh e)
    varL (PushLExpC _ (_::sh')) ZeroIdx _ cvtA
      = case matchShape (undefined :: sh) (undefined :: sh') of
          Just REFL -> Avar (cvtA ZeroIdx)
          _         -> INTERNAL_ERROR(error) "liftExp" "Unexpected incorrect shape"
    varL (PushExpC _)    ZeroIdx      cvtE _    = replicate (weakenE (SuccIdx . SuccIdx) $ Var $ cvtE ZeroIdx)
    varL (PushExpC d)    (SuccIdx ix) cvtE cvtA = varL d ix (cvtE . SuccIdx) cvtA
    varL (PushLExpC d _) (SuccIdx ix) cvtE cvtA = varL d ix cvtE             (cvtA . SuccIdx)
    varL (PushAccC d)    ix           cvtE cvtA = varL d ix cvtE             (cvtA . SuccIdx)
    varL _               _            _    _    = INTERNAL_ERROR(error) "liftExp" "Inconsistent valuation"

    letL :: forall bnd_t. (Elt e, Elt bnd_t)
         => PreOpenExp acc env          aenv  bnd_t
         -> PreOpenExp acc (env, bnd_t) aenv  e
         -> PreOpenAcc acc (env',sh)      aenv' (Array sh e)
    letL bnd body = Alet bnd' (inject body')
      where
        bnd'  = cvtE bnd

        body' :: PreOpenAcc acc (env',sh) (aenv', Array sh bnd_t) (Array sh e)
        body' = liftExp vectAcc (PushLExpC ctx (undefined :: sh)) body

    condL :: Elt e
          => PreOpenExp acc env     aenv  Bool
          -> PreOpenExp acc env     aenv  e
          -> PreOpenExp acc env     aenv  e
          -> PreOpenAcc acc (env',sh) aenv' (Array sh e)
    condL p t e = ZipWith (fun2 decide) (cvtE p) (inject $ ZipWith (fun2 tup) (cvtE t) (cvtE e))
      where
        decide p' ab = Cond p' (Prj (SuccTupIdx ZeroTupIdx) ab) (Prj ZeroTupIdx ab)

    -- while p it i
    --   => fst $ awhile (\(_,flags) -> any flags)
    --                   (\(values, flags) ->
    --                     let
    --                       values'  = zip (it^ values) flags
    --                       values'' = zipWith (\(v', f) v -> if f then v' else v) values' values
    --                       flags'   = p^ values''
    --                     in (values'', flags')
    --                   )
    --                   (i^, replicate sh False)
    --
    whileL :: Elt e
           => PreOpenFun acc env     aenv  (e -> Bool)
           -> PreOpenFun acc env     aenv  (e -> e)
           -> PreOpenExp acc env     aenv  e
           -> PreOpenAcc acc (env',sh) aenv' (Array sh e)
    whileL p it i = Aprj (SuccTupIdx ZeroTupIdx) (inject $ Awhile p' it' i')
      where
        p'  :: PreOpenAfun acc (env',sh) aenv' ((Array sh e, Array sh Bool) -> Scalar Bool)
        p'  = Alam $ Abody $ let
                flags     = sndA (inject $ Avar ZeroIdx)
                any     f = inject $ Fold or (Const ((),False)) (flatten f)
                or        = Lam $ Lam $ Body $ PrimApp PrimLOr $ tup (Var ZeroIdx) (Var (SuccIdx ZeroIdx))
                flatten a = inject $ Reshape (IndexCons IndexNil $ ShapeSize $ Var ZeroIdx) a
              in any flags

        it' :: PreOpenAfun acc (env',sh) aenv' ((Array sh e, Array sh Bool) -> (Array sh e, Array sh Bool))
        it' = Alam $ Abody $ let
                values  = fstA (inject $ Avar ZeroIdx)
                flags   = sndA (inject $ Avar ZeroIdx)
                values' = inject $ ZipWith (Lam $ Lam $ Body $ tup (Var $ SuccIdx ZeroIdx) (Var ZeroIdx))
                                           (inject $ weakenATop (cvtF1 it) `subApply` values)
                                           flags
                values'' = inject $ ZipWith (Lam $ Lam $ Body $ Cond (sndE $ Var $ SuccIdx ZeroIdx)
                                                                     (fstE $ Var $ SuccIdx ZeroIdx)
                                                                     (Var ZeroIdx))
                                            values'
                                            values
                flags'   = inject $ (weakenATop2) (cvtF1 p) `subApply` (inject $ Avar ZeroIdx)
              in inject $ Alet values'' (atup (inject $ Avar ZeroIdx) flags')


        i'  :: acc (env',sh) aenv' (Array sh e, Array sh Bool)
        i'  = cvtE i `atup` inject (replicate (Const ((), True)))

    indexL :: forall sh'. (Elt e, Shape sh')
           => acc            env      aenv  (Array sh' e)
           -> PreOpenExp acc env      aenv  sh'
           -> PreOpenAcc acc (env',sh)  aenv' (Array sh e)
    indexL a sh = Alet (cvtE sh) (inject perm)
      where
        a'   = weakenATop (cvtA a)
        perm = Backpermute (Var ZeroIdx) f a'
        f    = Lam (Body (Index (inject $ Avar ZeroIdx) (Var ZeroIdx)))

    -- linearIndex a i
    --   => let x = i^ in
    --        let a' = a^ in backpermute outShape (\sh -> fromIndex (shape a') (x ! sh)) a'
    --
    -- RCE: This transform could be done with a generate (and explicitly use LinearIndex), as
    -- opposed to a backpermute. The performance difference of the two should be investigated.
    linearIndexL :: forall sh'. (Elt e, Shape sh')
                 => acc            env     aenv  (Array sh' e)
                 -> PreOpenExp acc env     aenv  Int
                 -> PreOpenAcc acc (env',sh) aenv' (Array sh e)
    linearIndexL a i = Alet (cvtE i) (inject $ Alet a' (inject perm))
      where
        a'   = weakenATop (cvtA a)

        shr = Var ZeroIdx

        -- shape a
        sha = Shape (inject $ Avar ZeroIdx)

        -- backpermute (shape r) (\sh -> fromIndex (shape a') (x ! sh)) a'
        perm = Backpermute shr f (inject $ Avar ZeroIdx)

        -- (\sh -> fromIndex (shape a') (x ! sh))
        f    = Lam (Body (FromIndex sha (Index (inject $ Avar (SuccIdx ZeroIdx)) (Var ZeroIdx))))

    shapeL :: forall e'. (Shape e, Elt e')
           => acc            env     aenv  (Array e e')
           -> PreOpenAcc acc (env',sh) aenv' (Array sh e)
    shapeL a = Alet (cvtA a) (inject $ Generate (Var ZeroIdx) (Lam (Body (Shape (inject (Avar ZeroIdx))))))

    -- Utilities
    -- =========

    tup :: forall env aenv a b. (Elt a,Elt b)
        => PreOpenExp acc env aenv a
        -> PreOpenExp acc env aenv b
        -> PreOpenExp acc env aenv (a,b)
    tup a b = Tuple (SnocTup (SnocTup NilTup a) b)

    atup :: forall env aenv a b. (Arrays a, Arrays b)
         => acc env aenv a
         -> acc env aenv b
         -> acc env aenv (a,b)
    atup a b = inject $ Atuple $ NilAtup `SnocAtup` a `SnocAtup` b

    fstA :: forall env aenv a b. (Arrays a, Arrays b)
         => acc env aenv (a,b)
         -> acc env aenv a
    fstA t = inject $ Aprj (SuccTupIdx ZeroTupIdx) t

    sndA :: forall env aenv a b. (Arrays a, Arrays b)
         => acc env aenv (a,b)
         -> acc env aenv b
    sndA t = inject $ Aprj ZeroTupIdx t

    fstE :: forall env aenv a b. (Elt a, Elt b)
         => PreOpenExp acc env aenv (a,b)
         -> PreOpenExp acc env aenv a
    fstE = Prj (SuccTupIdx ZeroTupIdx)

    sndE :: forall env aenv a b. (Elt a, Elt b)
         => PreOpenExp acc env aenv (a,b)
         -> PreOpenExp acc env aenv b
    sndE = Prj ZeroTupIdx

    fun1 :: forall env aenv a b. (Elt a, Elt b)
         => (PreOpenExp acc (env,a) aenv a -> PreOpenExp acc (env,a) aenv b)
         -> PreOpenFun acc env aenv (a -> b)
    fun1 f = Lam (Body (f (Var ZeroIdx)))

    fun2 :: forall env aenv a b c. (Elt a, Elt b, Elt c)
         => (PreOpenExp acc ((env,a), b) aenv a -> PreOpenExp acc ((env,a), b) aenv b -> PreOpenExp acc ((env,a), b) aenv c)
         -> PreOpenFun acc env aenv (a -> b -> c)
    fun2 f = Lam (Lam (Body (f (Var (SuccIdx ZeroIdx)) (Var ZeroIdx))))


type family ArraysOfTupleRepr sh t
type instance ArraysOfTupleRepr sh ()    = ()
type instance ArraysOfTupleRepr sh (t,e) = (ArraysOfTupleRepr sh t, Array sh e)

type family ExpandEnv env env'
type instance ExpandEnv env ()        = env
type instance ExpandEnv env (env', t) = ExpandEnv (env, t) env'

type TupleEnv aenv sh t = ExpandEnv aenv (ArraysOfTupleRepr sh (TupleRepr t))

-- (a1, a2,..., aN) =>
--   let a1' = a1^
--       a2' = a2^
--       ...
--       aN' = aN^
--   in generate (\ix -> (a1' ! ix, a2' ! ix,..., aN' ! ix))
--
-- RCE: Ideally we would like to do this by lifting the tuple into a tuple of arrays.
-- Unfortunately this can't be done because the type system us unable to recognise that the
-- lifted tuple is an instance of IsTuple.
liftTuple :: forall acc env aenv env' aenv' sh e.
             (Elt e, Kit acc, Shape sh, IsTuple e)
          => VectoriseAcc acc
          -> Context env aenv env' aenv'
          -> Tuple (PreOpenExp acc env aenv) (TupleRepr e)
          -> PreOpenAcc acc (env',sh) aenv' (Array sh e)
liftTuple vectAcc ctx t = cvtT' t (inject . liftExp vectAcc ctx) gen
  where
    cvtT' :: forall t aenv'.
             Tuple (PreOpenExp acc env aenv) t
          -> (forall e. PreOpenExp acc env aenv e -> acc (env',sh) aenv' (Array sh e))
          -> PreOpenAcc acc (env',sh) (ExpandEnv aenv' (ArraysOfTupleRepr sh t)) (Array sh e)
          -> PreOpenAcc acc (env',sh) aenv'                                      (Array sh e)
    cvtT' NilTup        _    arr = arr
    cvtT'(SnocTup t' e) lift arr = Alet (lift e) (inject $ cvtT' t' lift' arr)
      where
        lift' :: forall e e'. PreOpenExp acc env aenv e -> acc (env',sh) (aenv', Array sh e') (Array sh e)
        lift' = weakenATop . lift

    gen :: PreOpenAcc acc (env',sh) (TupleEnv aenv' sh e) (Array sh e)
    gen = Generate (Var ZeroIdx) (Lam (Body (Tuple t')))
      where
        t' :: Tuple (PreOpenExp acc ((env',sh),sh) (TupleEnv aenv' sh e)) (TupleRepr e)
        t' = weakenTup (ixt (undefined :: aenv') t) (mkTup t)
          where
            mkTup :: forall e c. Tuple c e
                  -> Tuple (PreOpenExp acc ((env',sh),sh) (ArraysOfTupleRepr sh e)) e
            mkTup NilTup          = NilTup
            mkTup (SnocTup t'' _) = SnocTup (weakenTup SuccIdx (mkTup t'')) e'
              where
                e' :: forall s e'. e ~ (s,e') => PreOpenExp acc ((env',sh),sh) (ArraysOfTupleRepr sh e) e'
                e' = Index (inject (Avar ZeroIdx)) (Var ZeroIdx)

    weakenTup :: forall env aenv aenv' e. aenv :> aenv'
              -> Tuple (PreOpenExp acc env aenv) e
              -> Tuple (PreOpenExp acc env aenv') e
    weakenTup v = unRTup . weakenA v . RebuildTup

    tix :: forall t c env e. Tuple c t -> Idx env e -> Idx (ExpandEnv env (ArraysOfTupleRepr sh t)) e
    tix NilTup ix        = ix
    tix (SnocTup t (_:: c t')) ix = tix t ix'
      where
        ix' :: Idx (env, Array sh t') e
        ix' = SuccIdx ix

    ixt :: forall t c env e.
           env {- dummy -}
        -> Tuple c t
        -> Idx (ArraysOfTupleRepr sh t) e
        -> Idx (ExpandEnv env (ArraysOfTupleRepr sh t)) e
    ixt _   (SnocTup NilTup _) ZeroIdx      = ZeroIdx
    ixt _   (SnocTup t      _) ZeroIdx      = tix t (ZeroIdx :: Idx (env, e) e)
    ixt _   (SnocTup t      _) (SuccIdx ix) = ixt env' t ix
      where
        env' :: forall s e'. t ~ (s,e') => (env, Array sh e')
        env' = undefined -- dummy argument
    ixt _   _                  _            = error "Inconsistent valuation"

data Avoid f acc env aenv e where
  Avoided :: (Extend acc env aenv aenv', f acc env aenv' e) -> Avoid f acc env aenv e
  Unavoided :: Avoid f acc env aenv e

type AvoidExp = Avoid PreOpenExp
type AvoidFun = Avoid PreOpenFun

-- Avoid vectorisation in the cases where it's not necessary, or impossible.
--
avoidExp :: forall acc aenv env e. Kit acc
         => PreOpenExp acc env aenv e
         -> AvoidExp acc env aenv e
avoidExp = cvtE
  where
    cvtE :: forall e env aenv. PreOpenExp acc env aenv e -> AvoidExp acc env aenv e
    cvtE exp =
      case exp of
        Let a b             -> letA a b
        Var ix              -> simple $ Var ix
        Const c             -> simple $ Const c
        Tuple tup           -> cvtT tup
        Prj tup e           -> Prj tup `cvtE1` e
        IndexNil            -> simple IndexNil
        IndexCons sh sz     -> cvtE2 IndexCons sh sz
        IndexHead sh        -> IndexHead `cvtE1` sh
        IndexTail sh        -> IndexTail `cvtE1` sh
        IndexAny            -> simple IndexAny
        IndexSlice x ix sh  -> cvtE2 (IndexSlice x) ix sh
        IndexFull x ix sl   -> cvtE2 (IndexFull x) ix sl
        ToIndex sh ix       -> cvtE2 ToIndex sh ix
        FromIndex sh ix     -> cvtE2 FromIndex sh ix
        Cond p t e          -> cvtE3 Cond p t e
        While p f x         -> whileA p f x
        PrimConst c         -> simple $ PrimConst c
        PrimApp f x         -> PrimApp f `cvtE1` x
        Index a sh          -> cvtA1E1 Index a sh
        LinearIndex a i     -> cvtA1E1 LinearIndex a i
        Shape a             -> Shape `cvtA1` a
        ShapeSize sh        -> ShapeSize `cvtE1` sh
        Intersect s t       -> cvtE2 Intersect s t
        Foreign ff f e      -> Foreign ff f `cvtE1` e

    letA :: forall bnd_t e env aenv. (Elt e, Elt bnd_t)
         => PreOpenExp acc env          aenv bnd_t
         -> PreOpenExp acc (env, bnd_t) aenv e
         -> AvoidExp acc env          aenv e
    letA bnd body | Avoided (env , bnd' ) <- cvtE bnd
                  , Avoided (env', body') <- cvtE (sink env body)
                  , Just env''                 <- strengthenExtendE (noTop Just) env'
                  = Avoided (join env env'', Let (sink env' bnd') body')
                  | otherwise
                  = Unavoided

    whileA :: forall e env aenv. Elt e
           => PreOpenFun acc env aenv (e -> Bool)
           -> PreOpenFun acc env aenv (e -> e)
           -> PreOpenExp acc env aenv e
           -> AvoidExp acc env aenv e
    whileA (Lam (Body p)) (Lam (Body it)) i
      | Avoided (env0,  p') <- cvtE p
      , Avoided (env1, it') <- cvtE (sink env0 it)
      , Avoided (env2,  i') <- cvtE (sink env1 $ sink env0 i)
      , Just env0'          <- strengthenExtendE (noTop Just) env0
      , Just env1'          <- strengthenExtendE (noTop Just) env1
      = let
          p''  = (sink env2 . sink env1) p'
          it'' = sink env2 it'
        in Avoided (env0' `join` env1' `join` env2, While (Lam $ Body p'') (Lam $ Body it'') i')
    whileA _               _              _ = Unavoided


    simple :: forall e env aenv.
              PreOpenExp acc env aenv e
           -> AvoidExp      acc env aenv e
    simple e = Avoided (BaseEnv, e)

    cvtE1 :: forall e a env aenv. (forall env aenv. PreOpenExp acc env aenv a -> PreOpenExp acc env aenv e)
          -> PreOpenExp acc env aenv a
          -> AvoidExp acc env aenv e
    cvtE1 f (cvtE -> Avoided (env, a)) = Avoided (env, f a)
    cvtE1 _ _                          = Unavoided

    cvtE2 :: forall e a b env aenv.
             (forall env aenv. PreOpenExp acc env aenv a -> PreOpenExp acc env aenv b -> PreOpenExp acc env aenv e)
          -> PreOpenExp acc env aenv a
          -> PreOpenExp acc env aenv b
          -> AvoidExp acc env aenv e
    cvtE2 f (cvtE -> Avoided (env, a)) (cvtE . sink env -> Avoided (env', b))
      = Avoided (env `join` env', f (sink env' a) b)
    cvtE2 _ _                               _
      = Unavoided

    cvtE3 :: forall e a b c env aenv.
             (forall env aenv. PreOpenExp acc env aenv a -> PreOpenExp acc env aenv b -> PreOpenExp acc env aenv c -> PreOpenExp acc env aenv e)
          -> PreOpenExp acc env aenv a
          -> PreOpenExp acc env aenv b
          -> PreOpenExp acc env aenv c
          -> AvoidExp acc env aenv e
    cvtE3 f (cvtE                        -> Avoided (env, a))
            (cvtE . sink env             -> Avoided (env', b))
            (cvtE . sink env' . sink env -> Avoided (env'', c))
      = Avoided (env `join` env' `join` env'', f (sink env'' $ sink env' a) (sink env'' b) c)
    cvtE3 _ _ _ _ = Unavoided

    cvtT :: forall e env aenv. (IsTuple e, Elt e)
         => Tuple (PreOpenExp acc env aenv) (TupleRepr e)
         -> AvoidExp acc env aenv e
    cvtT t | Avoided (env, RebuildTup t) <- cvtT' t = Avoided (env, Tuple t)
      where
        cvtT' :: forall e.
                 Tuple (PreOpenExp acc env aenv) e
              -> Avoid RebuildTup acc env aenv e
        cvtT' NilTup        = Avoided (BaseEnv, (RebuildTup NilTup))
        cvtT' (SnocTup t e) | Avoided (env, RebuildTup t') <- cvtT' t
                            , Avoided (env', e') <- cvtE . sink env $ e
                            = Avoided (env `join` env', RebuildTup (SnocTup (unRTup $ sink env' $ RebuildTup t') e'))
        cvtT' _             = Unavoided
    cvtT _ = Unavoided

    cvtA1 :: forall a e env aenv. Arrays a
          => (forall env aenv. acc env aenv a -> PreOpenExp acc env aenv e)
          -> acc env aenv a
          -> AvoidExp acc env aenv e
    cvtA1 f a = Avoided (BaseEnv `PushEnv` extract a, f (inject $ Avar ZeroIdx))

    cvtA1E1 :: forall a b e env aenv. Arrays a
          => (forall env aenv. acc env aenv a -> PreOpenExp acc env aenv b -> PreOpenExp acc env aenv e)
          -> acc env aenv a
          -> PreOpenExp acc env aenv b
          -> AvoidExp acc env aenv e
    cvtA1E1 f a (cvtE -> Avoided (env, b))
      = Avoided (env `PushEnv` sink env (extract a), f (inject $ Avar ZeroIdx) (weakenATop b))
    cvtA1E1 _ _ _
      = Unavoided

avoidFun :: Kit acc
         => PreOpenFun acc env aenv f
         -> AvoidFun acc env aenv f
avoidFun (Lam f)  | Avoided (env, f') <- avoidFun f
                  , Just env'              <- strengthenExtendE (noTop Just) env
                  = Avoided (env', Lam f')
avoidFun (Body f) | Avoided (env, f') <- avoidExp f
                  = Avoided (env, Body f')
avoidFun _        = Unavoided

data ExtendContext env env' aenv where
  ExtendContext :: Context env aenv env' aenv' -> ExtendContext env env' aenv

extendContext :: Extend acc env aenv0 aenv1
            -> Context env aenv0 env' aenv0'
            -> ExtendContext env env' aenv1
extendContext BaseEnv d         = ExtendContext d
extendContext (PushEnv env _) d | ExtendContext d' <- extendContext env d
                              = ExtendContext (PushAccC d')

liftExtend :: Kit acc
           => VectoriseAcc acc
           -> Extend acc env aenv0 aenv1
           -> Context env aenv0 env' aenv0'
           -> Context env aenv1 env' aenv1'
           -> Extend acc env' aenv0' aenv1'
liftExtend _ BaseEnv d0 d1 | REFL <- mD d0 d1
                           = BaseEnv
  where
    mD :: Context env aenv env' aenv'
       -> Context env aenv env' aenv''
       -> aenv' :=: aenv''
    mD EmptyC EmptyC = REFL
    mD (PushAccC d1) (PushAccC d2) | REFL <- mD d1 d2
                                   = REFL
    mD (PushExpC d1) (PushExpC d2) | REFL <- mD d1 d2
                                   = REFL
    mD (PushLExpC d1 sh1) (PushLExpC d2 sh2) | REFL <- mD d1 d2
                                             , Just REFL <- matchShape sh1 sh2
                                             = REFL
    mD _                  _                  = INTERNAL_ERROR(error) "liftExtend" "2nd Context is not an extension of the first"

liftExtend k (PushEnv env a) d0 (PushAccC d1) = PushEnv (liftExtend k env d0 d1) (extract $ k d1 $ inject a)
liftExtend _ _               _  _             = INTERNAL_ERROR(error) "liftExtend" "Extended lifting context does not match environment extension"

-- Utility functions
-- ------------------

topEA :: forall acc env aenv t. (Kit acc, Elt t)
      => PreOpenExp acc env (aenv, Array Z t) t
topEA = Index (inject (Avar ZeroIdx)) (Const ())

noTop :: (env     :?> env')
      -> ((env,s) :?> env')
noTop _   ZeroIdx      = Nothing
noTop ixt (SuccIdx ix) = ixt ix

weakenATop :: Rebuildable f
           => f env aenv     t
           -> f env (aenv,s) t
weakenATop = weakenA SuccIdx

weakenATop2 :: Rebuildable f
            => f env aenv       t
            -> f env ((aenv,r),s) t
weakenATop2 = weakenA (SuccIdx . SuccIdx)

strengthenExtendE :: Kit acc
                  => (env :?> env')
                  -> Extend acc env aenv aenv'
                  -> Maybe (Extend acc env' aenv aenv')
strengthenExtendE _   BaseEnv         = Just BaseEnv
strengthenExtendE ixt (PushEnv env a) = PushEnv <$> strengthenExtendE ixt env <*> strengthenE ixt a

matchShape :: (Shape sh1, Shape sh2) => sh1 -> sh2 -> Maybe (sh1 :=: sh2)
matchShape _ _ = gcast REFL -- TODO: Have a way to reify shapes

unliftA :: forall env aenv env' aenv'.
           Context env aenv env' aenv'
        -> (aenv :> aenv')
unliftA (PushAccC _)    ZeroIdx      = ZeroIdx
unliftA (PushAccC d)    (SuccIdx ix) = SuccIdx $ unliftA d ix
unliftA (PushExpC d)    ix           = unliftA d ix
unliftA (PushLExpC d _) ix           = SuccIdx $ unliftA d ix
unliftA _               _            = error "unliftA: Inconsistent evalution"

unliftE :: forall env aenv env' aenv'.
           Context env aenv env' aenv'
        -> (env :?> env')
unliftE (PushAccC d)    ix           = unliftE d ix
unliftE (PushExpC _)    ZeroIdx      = Just ZeroIdx
unliftE (PushExpC d)    (SuccIdx ix) = SuccIdx <$> unliftE d ix
unliftE (PushLExpC _ _) ZeroIdx      = Nothing
unliftE (PushLExpC d _) (SuccIdx ix) = unliftE d ix
unliftE _               _            = error "unliftE: Inconsistent evalution"

rebuildToLift :: Rebuildable f
              => Context env aenv env' aenv'
              -> f env  aenv  t
              -> Maybe (f env' aenv' t)
rebuildToLift d = rebuild (liftA Var . unliftE d) (Just . Avar . unliftA d)