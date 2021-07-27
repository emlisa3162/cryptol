-- |
-- Module      :  Cryptol.TypeCheck.Infer
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable
--
-- Assumes that the `NoPat` pass has been run.

{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE Safe #-}
module Cryptol.TypeCheck.Infer
  ( checkE
  , checkSigB
  , inferModule
  , inferBinds
  , checkTopDecls
  )
where

import Data.Text(Text)
import qualified Data.Text as Text


import           Cryptol.ModuleSystem.Name (lookupPrimDecl,nameLoc)
import           Cryptol.Parser.Position
import qualified Cryptol.Parser.AST as P
import qualified Cryptol.ModuleSystem.Exports as P
import           Cryptol.ModuleSystem.Interface
import           Cryptol.TypeCheck.AST hiding (tSub,tMul,tExp)
import           Cryptol.TypeCheck.Monad
import           Cryptol.TypeCheck.Error
import           Cryptol.TypeCheck.Solve
import           Cryptol.TypeCheck.SimpType(tMul)
import           Cryptol.TypeCheck.Kind(checkType,checkSchema,checkTySyn,
                                        checkPropSyn,checkNewtype,
                                        checkParameterType,
                                        checkPrimType,
                                        checkParameterConstraints)
import           Cryptol.TypeCheck.Instantiate
import           Cryptol.TypeCheck.Subst (listSubst,apSubst,(@@),isEmptySubst)
import           Cryptol.Utils.Ident
import           Cryptol.Utils.Panic(panic)
import           Cryptol.Utils.RecordMap

import qualified Data.Map as Map
import           Data.Map (Map)
import qualified Data.Set as Set
import           Data.List(foldl',sortBy,groupBy)
import           Data.Either(partitionEithers)
import           Data.Maybe(isJust, fromMaybe, mapMaybe)
import           Data.List(partition)
import           Data.Ratio(numerator,denominator)
import           Data.Traversable(forM)
import           Data.Function(on)
import           Control.Monad(zipWithM,unless,foldM,forM_)



inferModule :: P.Module Name -> InferM Module
inferModule m =
  do newModuleScope (thing (P.mName m)) (map thing (P.mImports m))
                                        (P.modExports m)
     checkTopDecls (P.mDecls m)
     proveModuleTopLevel
     endModule

-- | Construct a Prelude primitive in the parsed AST.
mkPrim :: String -> InferM (P.Expr Name)
mkPrim str =
  do nm <- mkPrim' str
     return (P.EVar nm)

-- | Construct a Prelude primitive in the parsed AST.
mkPrim' :: String -> InferM Name
mkPrim' str =
  do prims <- getPrimMap
     return (lookupPrimDecl (prelPrim (Text.pack str)) prims)



desugarLiteral :: P.Literal -> InferM (P.Expr Name)
desugarLiteral lit =
  do l <- curRange
     numberPrim <- mkPrim "number"
     fracPrim   <- mkPrim "fraction"
     let named (x,y)  = P.NamedInst
                        P.Named { name = Located l (packIdent x), value = y }
         number fs    = P.EAppT numberPrim (map named fs)
         tBits n = P.TSeq (P.TNum n) P.TBit

     return $ case lit of

       P.ECNum num info ->
         number $ [ ("val", P.TNum num) ] ++ case info of
           P.BinLit _ n  -> [ ("rep", tBits (1 * toInteger n)) ]
           P.OctLit _ n  -> [ ("rep", tBits (3 * toInteger n)) ]
           P.HexLit _ n  -> [ ("rep", tBits (4 * toInteger n)) ]
           P.DecLit _    -> [ ]
           P.PolyLit _n  -> [ ("rep", P.TSeq P.TWild P.TBit) ]

       P.ECFrac fr info ->
         let arg f = P.PosInst (P.TNum (f fr))
             rnd   = P.PosInst (P.TNum (case info of
                                          P.DecFrac _ -> 0
                                          P.BinFrac _ -> 1
                                          P.OctFrac _ -> 1
                                          P.HexFrac _ -> 1))
         in P.EAppT fracPrim [ arg numerator, arg denominator, rnd ]

       P.ECChar c ->
         number [ ("val", P.TNum (toInteger (fromEnum c)))
                , ("rep", tBits (8 :: Integer)) ]

       P.ECString s ->
          P.ETyped (P.EList [ P.ELit (P.ECChar c) | c <- s ])
                   (P.TSeq P.TWild (P.TSeq (P.TNum 8) P.TBit))



-- | Infer the type of an expression with an explicit instantiation.
appTys :: P.Expr Name -> [TypeArg] -> TypeWithSource -> InferM Expr
appTys expr ts tGoal =
  case expr of
    P.EVar x ->
      do res <- lookupVar x
         (e',t) <- case res of
           ExtVar s   -> instantiateWith x (EVar x) s ts
           CurSCC e t -> do checkNoParams ts
                            return (e,t)

         checkHasType t tGoal
         return e'

    P.ELit l -> do e <- desugarLiteral l
                   appTys e ts tGoal


    P.EAppT e fs -> appTys e (map uncheckedTypeArg fs ++ ts) tGoal

    -- Here is an example of why this might be useful:
    -- f ` { x = T } where type T = ...
    P.EWhere e ds ->
      do (e1,ds1) <- checkLocalDecls ds (appTys e ts tGoal)
         pure (EWhere e1 ds1)

    P.ELocated e r ->
      do e' <- inRange r (appTys e ts tGoal)
         cs <- getCallStacks
         if cs then pure (ELocated r e') else pure e'

    P.ENeg        {} -> mono
    P.EComplement {} -> mono
    P.EGenerate   {} -> mono

    P.ETuple    {} -> mono
    P.ERecord   {} -> mono
    P.EUpd      {} -> mono
    P.ESel      {} -> mono
    P.EList     {} -> mono
    P.EFromTo   {} -> mono
    P.EFromToBy {} -> mono
    P.EFromToDownBy {} -> mono
    P.EFromToLessThan {} -> mono
    P.EInfFrom  {} -> mono
    P.EComp     {} -> mono
    P.EApp      {} -> mono
    P.EIf       {} -> mono
    P.ETyped    {} -> mono
    P.ETypeVal  {} -> mono
    P.EFun      {} -> mono
    P.ESplit    {} -> mono

    P.EParens e       -> appTys e ts tGoal
    P.EInfix a op _ b -> appTys (P.EVar (thing op) `P.EApp` a `P.EApp` b) ts tGoal

  where mono = do e' <- checkE expr tGoal
                  checkNoParams ts
                  return e'

checkNoParams :: [TypeArg] -> InferM ()
checkNoParams ts =
  case pos of
    p : _ -> do r <- case tyArgType p of
                       Unchecked t | Just r <- getLoc t -> pure r
                       _ -> curRange
                inRange r (recordError TooManyPositionalTypeParams)
    _ -> mapM_ badNamed named
  where
  badNamed l =
    case tyArgName l of
      Just i  -> recordError (UndefinedTypeParameter i)
      Nothing -> return ()

  (named,pos) = partition (isJust . tyArgName) ts


checkTypeOfKind :: P.Type Name -> Kind -> InferM Type
checkTypeOfKind ty k = checkType ty (Just k)


-- | Infer the type of an expression, and translate it to a fully elaborated
-- core term.
checkE :: P.Expr Name -> TypeWithSource -> InferM Expr
checkE expr tGoal =
  case expr of
    P.EVar x ->
      do res <- lookupVar x
         (e',t) <- case res of
                     ExtVar s   -> instantiateWith x (EVar x) s []
                     CurSCC e t -> return (e, t)

         checkHasType t tGoal
         return e'

    P.ENeg e ->
      do prim <- mkPrim "negate"
         checkE (P.EApp prim e) tGoal

    P.EComplement e ->
      do prim <- mkPrim "complement"
         checkE (P.EApp prim e) tGoal

    P.EGenerate e ->
      do prim <- mkPrim "generate"
         checkE (P.EApp prim e) tGoal

    P.ELit l@(P.ECNum _ (P.DecLit _)) ->
      do e <- desugarLiteral l
         -- NOTE: When 'l' is a decimal literal, 'desugarLiteral' does
         -- not generate an instantiation for the 'rep' type argument
         -- of the 'number' primitive. Therefore we explicitly
         -- instantiate 'rep' to 'tGoal' in this case to avoid
         -- generating an unnecessary unification variable.
         loc <- curRange
         let arg = TypeArg { tyArgName = Just (Located loc (packIdent "rep"))
                           , tyArgType = Checked (twsType tGoal)
                           }
         appTys e [arg] tGoal

    P.ELit l -> (`checkE` tGoal) =<< desugarLiteral l

    P.ETuple es ->
      do etys <- expectTuple (length es) tGoal
         let mkTGoal n t = WithSource t (TypeOfTupleField n)
         es'  <- zipWithM checkE es (zipWith mkTGoal [1..] etys)
         return (ETuple es')

    P.ERecord fs ->
      do es  <- expectRec fs tGoal
         let checkField f (e,t) = checkE e (WithSource t (TypeOfRecordField f))
         es' <- traverseRecordMap checkField es
         return (ERec es')

    P.EUpd x fs -> checkRecUpd x fs tGoal

    P.ESel e l ->
      do let src = selSrc l
         t <- newType src KType
         e' <- checkE e (WithSource t src)
         f <- newHasGoal l t (twsType tGoal)
         return (hasDoSelect f e')

    P.EList [] ->
      do (len,a) <- expectSeq tGoal
         expectFin 0 (WithSource len LenOfSeq)
         return (EList [] a)

    P.EList es ->
      do (len,a) <- expectSeq tGoal
         expectFin (length es) (WithSource len LenOfSeq)
         let checkElem e = checkE e (WithSource a TypeOfSeqElement)
         es' <- mapM checkElem es
         return (EList es' a)

    P.EFromToBy isStrict t1 t2 t3 mety
      | isStrict ->
        do l <- curRange
           let fs = [("first",t1),("bound",t2),("stride",t3)] ++
                    case mety of
                      Just ety -> [("a",ety)]
                      Nothing  -> []
           prim <- mkPrim "fromToByLessThan"
           let e' = P.EAppT prim
                    [ P.NamedInst P.Named{ name = Located l (packIdent x), value = y }
                    | (x,y) <- fs
                    ]
           checkE e' tGoal
      | otherwise ->
        do l <- curRange
           let fs = [("first",t1),("last",t2),("stride",t3)] ++
                    case mety of
                      Just ety -> [("a",ety)]
                      Nothing  -> []
           prim <- mkPrim "fromToBy"
           let e' = P.EAppT prim
                    [ P.NamedInst P.Named{ name = Located l (packIdent x), value = y }
                    | (x,y) <- fs
                    ]
           checkE e' tGoal

    P.EFromToDownBy isStrict t1 t2 t3 mety
      | isStrict ->
        do l <- curRange
           let fs = [("first",t1),("bound",t2),("stride",t3)] ++
                    case mety of
                      Just ety -> [("a",ety)]
                      Nothing  -> []
           prim <- mkPrim "fromToDownByGreaterThan"
           let e' = P.EAppT prim
                    [ P.NamedInst P.Named{ name = Located l (packIdent x), value = y }
                    | (x,y) <- fs
                    ]
           checkE e' tGoal
      | otherwise ->
        do l <- curRange
           let fs = [("first",t1),("last",t2),("stride",t3)] ++
                    case mety of
                      Just ety -> [("a",ety)]
                      Nothing  -> []
           prim <- mkPrim "fromToDownBy"
           let e' = P.EAppT prim
                    [ P.NamedInst P.Named{ name = Located l (packIdent x), value = y }
                    | (x,y) <- fs
                    ]
           checkE e' tGoal

    P.EFromToLessThan t1 t2 mety ->
      do l <- curRange
         let fs0 =
               case mety of
                 Just ety -> [("a", ety)]
                 Nothing  -> []
         let fs = [("first", t1), ("bound", t2)] ++ fs0
         prim <- mkPrim "fromToLessThan"
         let e' = P.EAppT prim
                  [ P.NamedInst P.Named { name = Located l (packIdent x), value = y }
                  | (x,y) <- fs
                  ]
         checkE e' tGoal

    P.EFromTo t1 mbt2 t3 mety ->
      do l <- curRange
         let fs0 =
               case mety of
                 Just ety -> [("a", ety)]
                 Nothing -> []
         let (c,fs) =
               case mbt2 of
                 Nothing ->
                    ("fromTo", ("last", t3) : fs0)
                 Just t2 ->
                    ("fromThenTo", ("next",t2) : ("last",t3) : fs0)

         prim <- mkPrim c
         let e' = P.EAppT prim
                  [ P.NamedInst P.Named { name = Located l (packIdent x), value = y }
                  | (x,y) <- ("first",t1) : fs
                  ]

         checkE e' tGoal

    P.EInfFrom e1 Nothing ->
      do prim <- mkPrim "infFrom"
         checkE (P.EApp prim e1) tGoal

    P.EInfFrom e1 (Just e2) ->
      do prim <- mkPrim "infFromThen"
         checkE (P.EApp (P.EApp prim e1) e2) tGoal

    P.EComp e mss ->
      do (mss', dss, ts) <- unzip3 `fmap` zipWithM inferCArm [ 1 .. ] mss
         (len,a) <- expectSeq tGoal

         inferred <- smallest ts
         ctrs <- unify (WithSource len LenOfSeq) inferred
         newGoals CtComprehension ctrs

         ds     <- combineMaps dss
         e'     <- withMonoTypes ds (checkE e (WithSource a TypeOfSeqElement))
         return (EComp len a e' mss')
      where
      -- the renamer should have made these checks already?
      combineMaps ms = if null bad
                          then return (Map.unions ms)
                          else panic "combineMaps" $ "Multiple definitions"
                                                      : map show bad
          where
          bad = do m <- ms
                   duplicates [ a { thing = x } | (x,a) <- Map.toList m ]
          duplicates = mapMaybe multiple
                     . groupBy ((==) `on` thing)
                     . sortBy (compare `on` thing)
            where
            multiple xs@(x : _ : _) = Just (thing x, map srcRange xs)
            multiple _              = Nothing



    P.EAppT e fs -> appTys e (map uncheckedTypeArg fs) tGoal

    P.EApp e1 e2 ->
      do let argSrc = TypeOfArg noArgDescr
         t1  <- newType argSrc  KType
         e1' <- checkE e1 (WithSource (tFun t1 (twsType tGoal)) FunApp)
         e2' <- checkE e2 (WithSource t1 argSrc)
         return (EApp e1' e2')

    P.EIf e1 e2 e3 ->
      do e1'      <- checkE e1 (WithSource tBit TypeOfIfCondExpr)
         e2'      <- checkE e2 tGoal
         e3'      <- checkE e3 tGoal
         return (EIf e1' e2' e3')

    P.EWhere e ds ->
      do (e1,ds1) <- checkLocalDecls ds (checkE e tGoal)
         pure (EWhere e1 ds1)

    P.ETyped e t ->
      do tSig <- checkTypeOfKind t KType
         e' <- checkE e (WithSource tSig TypeFromUserAnnotation)
         checkHasType tSig tGoal
         return e'

    P.ETypeVal t ->
      do l <- curRange
         prim <- mkPrim "number"
         checkE (P.EAppT prim
                  [P.NamedInst
                   P.Named { name = Located l (packIdent "val")
                           , value = t }]) tGoal

    P.EFun desc ps e -> checkFun desc ps e tGoal

    P.ELocated e r  ->
      do e' <- inRange r (checkE e tGoal)
         cs <- getCallStacks
         if cs then pure (ELocated r e') else pure e'

    P.ESplit e ->
      do prim <- mkPrim "splitAt"
         checkE (P.EApp prim e) tGoal

    P.EInfix a op _ b -> checkE (P.EVar (thing op) `P.EApp` a `P.EApp` b) tGoal

    P.EParens e -> checkE e tGoal


checkRecUpd ::
  Maybe (P.Expr Name) -> [ P.UpdField Name ] -> TypeWithSource -> InferM Expr
checkRecUpd mb fs tGoal =
  case mb of

    -- { _ | fs } ~~>  \r -> { r | fs }
    Nothing ->
      do r <- newParamName NSValue (packIdent "r")
         let p  = P.PVar Located { srcRange = nameLoc r, thing = r }
             fe = P.EFun P.emptyFunDesc [p] (P.EUpd (Just (P.EVar r)) fs)
         checkE fe tGoal

    Just e ->
      do e1 <- checkE e tGoal
         foldM doUpd e1 fs

  where
  doUpd e (P.UpdField how sels v) =
    case sels of
      [l] ->
        case how of
          P.UpdSet ->
            do let src = selSrc s
               ft <- newType src KType
               v1 <- checkE v (WithSource ft src)
               d  <- newHasGoal s (twsType tGoal) ft
               pure (hasDoSet d e v1)
          P.UpdFun ->
             do let src = selSrc s
                ft <- newType src KType
                v1 <- checkE v (WithSource (tFun ft ft) src)
                -- XXX: ^ may be used a different src?
                d  <- newHasGoal s (twsType tGoal) ft
                tmp <- newParamName NSValue (packIdent "rf")
                let e' = EVar tmp
                pure $ hasDoSet d e' (EApp v1 (hasDoSelect d e'))
                       `EWhere`
                       [  NonRecursive
                          Decl { dName        = tmp
                               , dSignature   = tMono (twsType tGoal)
                               , dDefinition  = DExpr e
                               , dPragmas     = []
                               , dInfix       = False
                               , dFixity      = Nothing
                               , dDoc         = Nothing
                               } ]

        where s = thing l
      _ -> panic "checkRecUpd/doUpd" [ "Expected exactly 1 field label"
                                     , "Got: " ++ show (length sels)
                                     ]


expectSeq :: TypeWithSource -> InferM (Type,Type)
expectSeq tGoal@(WithSource ty src) =
  case ty of

    TUser _ _ ty' ->
         expectSeq (WithSource ty' src)

    TCon (TC TCSeq) [a,b] ->
         return (a,b)

    TVar _ ->
      do tys@(a,b) <- genTys
         newGoals CtExactType =<< unify tGoal (tSeq a b)
         return tys

    _ ->
      do tys@(a,b) <- genTys
         recordError (TypeMismatch src ty (tSeq a b))
         return tys
  where
  genTys =
    do a <- newType LenOfSeq KNum
       b <- newType TypeOfSeqElement KType
       return (a,b)


expectTuple :: Int -> TypeWithSource -> InferM [Type]
expectTuple n tGoal@(WithSource ty src) =
  case ty of

    TUser _ _ ty' ->
         expectTuple n (WithSource ty' src)

    TCon (TC (TCTuple n')) tys | n == n' ->
         return tys

    TVar _ ->
      do tys <- genTys
         newGoals CtExactType =<< unify tGoal (tTuple tys)
         return tys

    _ ->
      do tys <- genTys
         recordError (TypeMismatch src ty (tTuple tys))
         return tys

  where
  genTys =forM [ 0 .. n - 1 ] $ \ i -> newType (TypeOfTupleField i) KType


expectRec ::
  RecordMap Ident (Range, a) ->
  TypeWithSource ->
  InferM (RecordMap Ident (a, Type))
expectRec fs tGoal@(WithSource ty src) =
  case ty of

    TUser _ _ ty' ->
         expectRec fs (WithSource ty' src)

    TRec ls
      | Right r <- zipRecords (\_ (_rng,v) t -> (v,t)) fs ls -> pure r

    _ ->
      do res <- traverseRecordMap
                  (\nm (_rng,v) ->
                       do t <- newType (TypeOfRecordField nm) KType
                          return (v, t))
                  fs
         let tys = fmap snd res
         case ty of
           TVar TVFree{} -> do ps <- unify tGoal (TRec tys)
                               newGoals CtExactType ps
           _ -> recordError (TypeMismatch src ty (TRec tys))
         return res


expectFin :: Int -> TypeWithSource -> InferM ()
expectFin n tGoal@(WithSource ty src) =
  case ty of

    TUser _ _ ty' ->
         expectFin n (WithSource ty' src)

    TCon (TC (TCNum n')) [] | toInteger n == n' ->
         return ()

    _ -> newGoals CtExactType =<< unify tGoal (tNum n)

expectFun :: Maybe Name -> Int -> TypeWithSource -> InferM ([Type],Type)
expectFun mbN n (WithSource ty0 src)  = go [] n ty0
  where

  go tys arity ty
    | arity > 0 =
      case ty of

        TUser _ _ ty' ->
             go tys arity ty'

        TCon (TC TCFun) [a,b] ->
             go (a:tys) (arity - 1) b

        _ ->
          do args <- genArgs arity
             res  <- newType TypeOfRes KType
             case ty of
               TVar TVFree{} ->
                  do ps <- unify (WithSource ty src) (foldr tFun res args)
                     newGoals CtExactType  ps
               _ -> recordError (TypeMismatch src ty (foldr tFun res args))
             return (reverse tys ++ args, res)

    | otherwise =
      return (reverse tys, ty)

  genArgs arity = forM [ 1 .. arity ] $
                    \ ix -> newType (TypeOfArg (ArgDescr mbN (Just ix))) KType


checkHasType :: Type -> TypeWithSource -> InferM ()
checkHasType inferredType tGoal =
  do ps <- unify tGoal inferredType
     case ps of
       [] -> return ()
       _  -> newGoals CtExactType ps


checkFun ::
  P.FunDesc Name -> [P.Pattern Name] ->
  P.Expr Name -> TypeWithSource -> InferM Expr
checkFun _    [] e tGoal = checkE e tGoal
checkFun (P.FunDesc fun offset) ps e tGoal =
  inNewScope
  do let descs = [ TypeOfArg (ArgDescr fun (Just n)) | n <- [ 1 + offset .. ] ]

     (tys,tRes) <- expectFun fun (length ps) tGoal
     largs      <- sequence (zipWith checkP ps (zipWith WithSource tys descs))
     let ds = Map.fromList [ (thing x, x { thing = t }) | (x,t) <- zip largs tys ]
     e1         <- withMonoTypes ds (checkE e (WithSource tRes TypeOfRes))

     let args = [ (thing x, t) | (x,t) <- zip largs tys ]
     return (foldr (\(x,t) b -> EAbs x t b) e1 args)


{-| The type the is the smallest of all -}
smallest :: [Type] -> InferM Type
smallest []   = newType LenOfSeq KNum
smallest [t]  = return t
smallest ts   = do a <- newType LenOfSeq KNum
                   newGoals CtComprehension [ a =#= foldr1 tMin ts ]
                   return a

checkP :: P.Pattern Name -> TypeWithSource -> InferM (Located Name)
checkP p tGoal@(WithSource _ src) =
  do (x, t) <- inferP p
     ps <- unify tGoal (thing t)
     let rng   = fromMaybe emptyRange (getLoc p)
     let mkErr = recordError . UnsolvedGoals . (:[])
                                                   . Goal (CtPattern src) rng
     mapM_ mkErr ps
     return (Located (srcRange t) x)

{-| Infer the type of a pattern.  Assumes that the pattern will be just
a variable. -}
inferP :: P.Pattern Name -> InferM (Name, Located Type)
inferP pat =
  case pat of

    P.PVar x0 ->
      do a   <- inRange (srcRange x0) (newType (DefinitionOf (thing x0)) KType)
         return (thing x0, x0 { thing = a })

    P.PTyped p t ->
      do tSig <- checkTypeOfKind t KType
         ln   <- checkP p (WithSource tSig TypeFromUserAnnotation)
         return (thing ln, ln { thing = tSig })

    _ -> tcPanic "inferP" [ "Unexpected pattern:", show pat ]



-- | Infer the type of one match in a list comprehension.
inferMatch :: P.Match Name -> InferM (Match, Name, Located Type, Type)
inferMatch (P.Match p e) =
  do (x,t) <- inferP p
     n     <- newType LenOfCompGen KNum
     e'    <- checkE e (WithSource (tSeq n (thing t)) GeneratorOfListComp)
     return (From x n (thing t) e', x, t, n)

inferMatch (P.MatchLet b)
  | P.bMono b =
  do let rng = srcRange (P.bName b)
     a <- inRange rng (newType (DefinitionOf (thing (P.bName b))) KType)
     b1 <- checkMonoB b a
     return (Let b1, dName b1, Located (srcRange (P.bName b)) a, tNum (1::Int))

  | otherwise = tcPanic "inferMatch"
                      [ "Unexpected polymorphic match let:", show b ]

-- | Infer the type of one arm of a list comprehension.
inferCArm :: Int -> [P.Match Name] -> InferM
              ( [Match]
              , Map Name (Located Type)-- defined vars
              , Type                   -- length of sequence
              )

inferCArm _ [] = panic "inferCArm" [ "Empty comprehension arm" ]
inferCArm _ [m] =
  do (m1, x, t, n) <- inferMatch m
     return ([m1], Map.singleton x t, n)

inferCArm armNum (m : ms) =
  do (m1, x, t, n)  <- inferMatch m
     (ms', ds, n')  <- withMonoType (x,t) (inferCArm armNum ms)
     newGoals CtComprehension [ pFin n' ]
     return (m1 : ms', Map.insertWith (\_ old -> old) x t ds, tMul n n')

-- | @inferBinds isTopLevel isRec binds@ performs inference for a
-- strongly-connected component of 'P.Bind's.
-- If any of the members of the recursive group are already marked
-- as monomorphic, then we don't do generalization.
-- If @isTopLevel@ is true,
-- any bindings without type signatures will be generalized. If it is
-- false, and the mono-binds flag is enabled, no bindings without type
-- signatures will be generalized, but bindings with signatures will
-- be unaffected.
inferBinds :: Bool -> Bool -> [P.Bind Name] -> InferM [Decl]
inferBinds isTopLevel isRec binds =
  do -- when mono-binds is enabled, and we're not checking top-level
     -- declarations, mark all bindings lacking signatures as monomorphic
     monoBinds <- getMonoBinds
     let (sigs,noSigs) = partition (isJust . P.bSignature) binds
         monos         = sigs ++ [ b { P.bMono = True } | b <- noSigs ]
         binds' | any P.bMono binds           = monos
                | monoBinds && not isTopLevel = monos
                | otherwise                   = binds

         check exprMap =
        {- Guess type is here, because while we check user supplied signatures
           we may generate additional constraints. For example, `x - y` would
           generate an additional constraint `x >= y`. -}
           do (newEnv,todos) <- unzip `fmap` mapM (guessType exprMap) binds'
              let otherEnv = filter isExt newEnv

              let (sigsAndMonos,noSigGen) = partitionEithers todos

              let prepGen = collectGoals
                          $ do bs <- sequence noSigGen
                               simplifyAllConstraints
                               return bs

              if isRec
                then
                  -- First we check the bindings with no signatures
                  -- that need to be generalized.
                  do (bs1,cs) <- withVarTypes newEnv prepGen

                     -- We add these to the environment, so their fvs are
                     -- not generalized.
                     genCs <- withVarTypes otherEnv (generalize bs1 cs)

                     -- Then we do all the rest,
                     -- using the newly inferred poly types.
                     let newEnv' = map toExt bs1 ++ otherEnv
                     done <- withVarTypes newEnv' (sequence sigsAndMonos)
                     return (done,genCs)

                else
                  do done      <- sequence sigsAndMonos
                     (bs1, cs) <- prepGen
                     genCs     <- generalize bs1 cs
                     return (done,genCs)

     rec
       let exprMap = Map.fromList (map monoUse genBs)
       (doneBs, genBs) <- check exprMap

     simplifyAllConstraints

     return (doneBs ++ genBs)

  where
  toExt d = (dName d, ExtVar (dSignature d))
  isExt (_,y) = case y of
                  ExtVar _ -> True
                  _        -> False

  monoUse d = (x, withQs)
    where
    x  = dName d
    as = sVars (dSignature d)
    qs = sProps (dSignature d)

    appT e a = ETApp e (TVar (tpVar a))
    appP e _ = EProofApp e

    withTys  = foldl' appT (EVar x) as
    withQs   = foldl' appP withTys  qs





{- | Come up with a type for recursive calls to a function, and decide
     how we are going to be checking the binding.
     Returns: (Name, type or schema, computation to check binding)

     The `exprMap` is a thunk where we can lookup the final expressions
     and we should be careful not to force it.
-}
guessType :: Map Name Expr -> P.Bind Name ->
              InferM ( (Name, VarType)
                     , Either (InferM Decl)    -- no generalization
                              (InferM Decl)    -- generalize these
                     )
guessType exprMap b@(P.Bind { .. }) =
  case bSignature of

    Just s ->
      do s1 <- checkSchema AllowWildCards s
         return ((name, ExtVar (fst s1)), Left (checkSigB b s1))

    Nothing
      | bMono ->
         do t <- newType (DefinitionOf name) KType
            let schema = Forall [] [] t
            return ((name, ExtVar schema), Left (checkMonoB b t))

      | otherwise ->

        do t <- newType (DefinitionOf name) KType
           let noWay = tcPanic "guessType" [ "Missing expression for:" ,
                                                                show name ]
               expr  = Map.findWithDefault noWay name exprMap

           return ((name, CurSCC expr t), Right (checkMonoB b t))
  where
  name = thing bName



{- | The inputs should be declarations with monomorphic types
(i.e., of the form `Forall [] [] t`). -}
generalize :: [Decl] -> [Goal] -> InferM [Decl]

{- This may happen because we have monomorphic bindings.
In this case we may get some goal, due to the monomorphic bindings,
but the group of components is empty. -}
generalize [] gs0 =
  do addGoals gs0
     return []


generalize bs0 gs0 =
  do {- First, we apply the accumulating substitution to the goals
        and the inferred types, to ensure that we have the most up
        to date information. -}
     gs <- applySubstGoals gs0
     bs <- forM bs0 $ \b -> do s <- applySubst (dSignature b)
                               return b { dSignature = s }

     -- Next, we figure out which of the free variables need to be generalized
     -- Variables apearing in the types of monomorphic bindings should
     -- not be generalizedr.
     let goalFVS g  = Set.filter isFreeTV $ fvs $ goal g
         inGoals    = Set.unions $ map goalFVS gs
         inSigs     = Set.filter isFreeTV $ fvs $ map dSignature bs
         candidates = (Set.union inGoals inSigs)

     asmpVs <- varsWithAsmps

     let gen0          = Set.difference candidates asmpVs
         stays g       = any (`Set.member` gen0) $ Set.toList $ goalFVS g
         (here0,later) = partition stays gs
     addGoals later   -- these ones we keep around for to solve later

     let maybeAmbig = Set.toList (Set.difference gen0 inSigs)

     {- See if we might be able to default some of the potentially ambiguous
        variables using the constraints that will be part of the newly
        generalized schema.  -}
     let (as0,here1,defSu,ws,errs) = defaultAndSimplify maybeAmbig here0

     extendSubst defSu
     mapM_ recordWarning ws
     mapM_ recordError errs
     let here = map goal here1


     {- This is the variables we'll be generalizing:
          * any ones that survived the defaulting
          * and vars in the inferred types that do not appear anywhere else. -}
     let as   = sortBy numFst
              $ as0 ++ Set.toList (Set.difference inSigs asmpVs)
         asPs = [ TParam { tpUnique = x
                         , tpKind   = k
                         , tpFlav   = TPUnifyVar
                         , tpInfo   = i
                         }
                | TVFree x k _ i <- as
                ]

     {- Finally, we replace free variables with bound ones, and fix-up
        the definitions as needed to reflect that we are now working
        with polymorphic things. For example, apply each occurrence to the
        type parameters. -}
     totSu <- getSubst
     let
         su     = listSubst (zip as (map (TVar . tpVar) asPs)) @@ totSu
         qs     = concatMap (pSplitAnd . apSubst su) here

         genE e = foldr ETAbs (foldr EProofAbs (apSubst su e) qs) asPs
         genB d = d { dDefinition = case dDefinition d of
                                      DExpr e -> DExpr (genE e)
                                      DPrim   -> DPrim
                    , dSignature  = Forall asPs qs
                                  $ apSubst su $ sType $ dSignature d
                    }

     return (map genB bs)

  where
  numFst x y = case (kindOf x, kindOf y) of
                 (KNum, KNum) -> EQ
                 (KNum, _)    -> LT
                 (_,KNum)     -> GT
                 _            -> EQ

-- | Check a monomorphic binding.
checkMonoB :: P.Bind Name -> Type -> InferM Decl
checkMonoB b t =
  inRangeMb (getLoc b) $
  case thing (P.bDef b) of

    P.DPrim -> panic "checkMonoB" ["Primitive with no signature?"]

    P.DExpr e ->
      do let nm = thing (P.bName b)
         let tGoal = WithSource t (DefinitionOf nm)
         e1 <- checkFun (P.FunDesc (Just nm) 0) (P.bParams b) e tGoal
         let f = thing (P.bName b)
         return Decl { dName = f
                     , dSignature = Forall [] [] t
                     , dDefinition = DExpr e1
                     , dPragmas = P.bPragmas b
                     , dInfix = P.bInfix b
                     , dFixity = P.bFixity b
                     , dDoc = P.bDoc b
                     }

-- XXX: Do we really need to do the defaulting business in two different places?
checkSigB :: P.Bind Name -> (Schema,[Goal]) -> InferM Decl
checkSigB b (Forall as asmps0 t0, validSchema) = case thing (P.bDef b) of

 -- XXX what should we do with validSchema in this case?
 P.DPrim ->
   do return Decl { dName       = thing (P.bName b)
                  , dSignature  = Forall as asmps0 t0
                  , dDefinition = DPrim
                  , dPragmas    = P.bPragmas b
                  , dInfix      = P.bInfix b
                  , dFixity     = P.bFixity b
                  , dDoc        = P.bDoc b
                  }

 P.DExpr e0 ->
  inRangeMb (getLoc b) $
  withTParams as $
  do (e1,cs0) <- collectGoals $
                do let nm = thing (P.bName b)
                       tGoal = WithSource t0 (DefinitionOf nm)
                   e1 <- checkFun (P.FunDesc (Just nm) 0) (P.bParams b) e0 tGoal
                   addGoals validSchema
                   () <- simplifyAllConstraints  -- XXX: using `asmps` also?
                   return e1

     asmps1 <- applySubstPreds asmps0
     cs     <- applySubstGoals cs0

     let findKeep vs keep todo =
          let stays (_,cvs)    = not $ Set.null $ Set.intersection vs cvs
              (yes,perhaps)    = partition stays todo
              (stayPs,newVars) = unzip yes
          in case stayPs of
               [] -> (keep,map fst todo)
               _  -> findKeep (Set.unions (vs:newVars)) (stayPs ++ keep) perhaps

     let -- if a goal mentions any of these variables, we'll commit to
         -- solving it now.
         stickyVars = Set.fromList (map tpVar as) `Set.union` fvs asmps1
         (stay,leave) = findKeep stickyVars []
                            [ (c, fvs c) | c <- cs ]

     addGoals leave


     su <- proveImplication (Just (thing (P.bName b))) as asmps1 stay
     extendSubst su

     let asmps  = concatMap pSplitAnd (apSubst su asmps1)
     t      <- applySubst t0
     e2     <- applySubst e1

     return Decl
        { dName       = thing (P.bName b)
        , dSignature  = Forall as asmps t
        , dDefinition = DExpr (foldr ETAbs (foldr EProofAbs e2 asmps) as)
        , dPragmas    = P.bPragmas b
        , dInfix      = P.bInfix b
        , dFixity     = P.bFixity b
        , dDoc        = P.bDoc b
        }


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

checkLocalDecls :: [P.Decl Name] -> InferM a -> InferM (a,[DeclGroup])
checkLocalDecls ds0 k =
  do newLocalScope
     forM_ ds0 \d -> checkDecl False d Nothing
     a <- k
     ds <- endLocalScope
     pure (a,ds)



checkTopDecls :: [P.TopDecl Name] -> InferM ()
checkTopDecls = mapM_ checkTopDecl
  where
  checkTopDecl decl =
    case decl of
      P.Decl tl -> checkDecl True (P.tlValue tl) (thing <$> P.tlDoc tl)

      P.TDNewtype tl ->
        do t <- checkNewtype (P.tlValue tl) (thing <$> P.tlDoc tl)
           addNewtype t

      P.DPrimType tl ->
        do t <- checkPrimType (P.tlValue tl) (thing <$> P.tlDoc tl)
           addPrimType t

      P.DParameterType ty ->
        do t <- checkParameterType ty
           addParamType t

      P.DParameterConstraint cs ->
        do cs1 <- checkParameterConstraints cs
           addParameterConstraints cs1

      P.DParameterFun pf ->
        do x <- checkParameterFun pf
           addParamFun x

      P.DModule tl ->
         do let P.NestedModule m = P.tlValue tl
            newSubmoduleScope (thing (P.mName m)) (map thing (P.mImports m))
                                                  (P.modExports m)
            checkTopDecls (P.mDecls m)
            endSubmodule

      P.DModSig tl ->
        do let sig = P.tlValue tl
           ps <- checkSignature sig (P.thing <$> P.tlDoc tl)
           addSignature (P.thing (P.sigName sig)) ps

      P.DImport {} -> pure ()
      P.Include {} -> panic "checkTopDecl" [ "Unexpected `inlude`" ]


checkDecl :: Bool -> P.Decl Name -> Maybe Text -> InferM ()
checkDecl isTopLevel d mbDoc =
  case d of

    P.DBind c ->
      do ~[b] <- inferBinds isTopLevel False [c]
         addDecls (NonRecursive b)

    P.DRec bs ->
      do bs1 <- inferBinds isTopLevel True bs
         addDecls (Recursive bs1)

    P.DType t ->
      do t1 <- checkTySyn t mbDoc
         addTySyn t1

    P.DProp t ->
      do t1 <- checkPropSyn t mbDoc
         addTySyn t1

    P.DLocated d' r -> inRange r (checkDecl isTopLevel d' mbDoc)

    P.DSignature {} -> bad "DSignature"
    P.DFixity {}    -> bad "DFixity"
    P.DPragma {}    -> bad "DPragma"
    P.DPatBind {}   -> bad "DPatBind"

  where
  bad x = panic "checkDecl" [x]


checkParameterFun :: P.ParameterFun Name -> InferM ModVParam
checkParameterFun x =
  do (s,gs) <- checkSchema NoWildCards (P.pfSchema x)
     su <- proveImplication (Just (thing (P.pfName x)))
                            (sVars s) (sProps s) gs
     unless (isEmptySubst su) $
       panic "checkParameterFun" ["Subst not empty??"]
     let n = thing (P.pfName x)
     return ModVParam { mvpName = n
                      , mvpType = s
                      , mvpDoc  = P.pfDoc x
                      , mvpFixity = P.pfFixity x
                      }


checkSignature :: P.Signature Name -> Maybe Text -> InferM IfaceParams
checkSignature sig mbDoc =
  do ts <- mapM checkParameterType (P.sigTypeParams sig)
     cs <- checkParameterConstraints (P.sigConstraints sig)
     fs <- mapM checkParameterFun (P.sigFunParams sig)
     pure IfaceParams
       { ifParamTypes       = Map.fromList [ (mtpName p,p) | p <- ts ]
       , ifParamConstraints = cs
       , ifParamFuns        = Map.fromList [ (mvpName p,p) | p <- fs ]
       , ifParamDoc         = mbDoc
       }


tcPanic :: String -> [String] -> a
tcPanic l msg = panic ("[TypeCheck] " ++ l) msg
