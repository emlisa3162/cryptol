{-# Language BlockArguments, OverloadedStrings #-}
{-# Language BangPatterns #-}
module Cryptol.Backend.FloatHelpers where

import Data.Char (isDigit)
import Data.Ratio(numerator,denominator)
import LibBF

import Cryptol.Utils.PP
import Cryptol.Utils.Panic(panic)
import Cryptol.Backend.Monad( EvalError(..) )


data BF = BF
  { bfExpWidth  :: !Integer
  , bfPrecWidth :: !Integer
  , bfValue     :: !BigFloat
  }


-- | Make LibBF options for the given precision and rounding mode.
fpOpts :: Integer -> Integer -> RoundMode -> BFOpts
fpOpts e p r =
  case ok of
    Just opts -> opts
    Nothing   -> panic "floatOpts" [ "Invalid Float size"
                                   , "exponent: " ++ show e
                                   , "precision: " ++ show p
                                   ]
  where
  ok = do eb <- rng expBits expBitsMin expBitsMax e
          pb <- rng precBits precBitsMin precBitsMax p
          pure (eb <> pb <> allowSubnormal <> rnd r)

  rng f a b x = if toInteger a <= x && x <= toInteger b
                  then Just (f (fromInteger x))
                  else Nothing



-- | Mapping from the rounding modes defined in the `Float.cry` to
-- the rounding modes of `LibBF`.
fpRound :: Integer -> Either EvalError RoundMode
fpRound n =
  case n of
    0 -> Right NearEven
    1 -> Right NearAway
    2 -> Right ToPosInf
    3 -> Right ToNegInf
    4 -> Right ToZero
    _ -> Left (BadRoundingMode n)

-- | Check that we didn't get an unexpected status.
fpCheckStatus :: (BigFloat,Status) -> BigFloat
fpCheckStatus (r,s) =
  case s of
    MemError  -> panic "checkStatus" [ "libBF: Memory error" ]
    _         -> r


-- | Pretty print a float
fpPP :: PPOpts -> BF -> Doc
fpPP opts bf =
  case bfSign num of
    Nothing -> "fpNaN"
    Just s
      | bfIsFinite num -> text hacStr
      | otherwise ->
        case s of
          Pos -> "fpPosInf"
          Neg -> "fpNegInf"
  where
  num = bfValue bf
  precW = bfPrecWidth bf

  base  = useFPBase opts

  withExp :: PPFloatExp -> ShowFmt -> ShowFmt
  withExp e f = case e of
                  AutoExponent -> f
                  ForceExponent -> f <> forceExp

  str = bfToString base fmt num
  fmt = addPrefix <> showRnd NearEven <>
        case useFPFormat opts of
          FloatFree e -> withExp e $ showFree
                                   $ Just $ fromInteger precW
          FloatFixed n e -> withExp e $ showFixed $ fromIntegral n
          FloatFrac n    -> showFrac $ fromIntegral n

  -- non-base 10 literals are not overloaded so we add an explicit
  -- .0 if one is not present.  Moreover, we trim any extra zeros
  -- that appear in a decimal representation.
  hacStr
    | base == 10   = trimZeros
    | elem '.' str = str
    | otherwise = case break (== 'p') str of
                    (xs,ys) -> xs ++ ".0" ++ ys

  trimZeros =
    case break (== '.') str of
      (xs,'.':ys) ->
        case break (not . isDigit) ys of
          (frac, suffix) -> xs ++ '.' : processFraction frac ++ suffix
      _ -> str

  processFraction frac =
    case dropWhile (== '0') (reverse frac) of
      [] -> "0"
      zs -> reverse zs

-- | Make a literal
fpLit ::
  Integer     {- ^ Exponent width -} ->
  Integer     {- ^ Precision width -} ->
  Rational ->
  BF
fpLit e p rat = floatFromRational e p NearEven rat

-- | Make a floating point number from a rational, using the given rounding mode
floatFromRational :: Integer -> Integer -> RoundMode -> Rational -> BF
floatFromRational e p r rat =
  BF { bfExpWidth = e
     , bfPrecWidth = p
     , bfValue = fpCheckStatus
                 if den == 1 then bfRoundFloat opts num
                             else bfDiv opts num (bfFromInteger den)
     }
  where
  opts  = fpOpts e p r

  num   = bfFromInteger (numerator rat)
  den   = denominator rat


-- | Convert a floating point number to a rational, if possible.
floatToRational :: String -> BF -> Either EvalError Rational
floatToRational fun bf =
  case bfToRep (bfValue bf) of
    BFNaN -> Left (BadValue fun)
    BFRep s num ->
      case num of
        Inf  -> Left (BadValue fun)
        Zero -> Right 0
        Num i ev -> Right case s of
                            Pos -> ab
                            Neg -> negate ab
          where ab = fromInteger i * (2 ^^ ev)


-- | Convert a floating point number to an integer, if possible.
floatToInteger :: String -> RoundMode -> BF -> Either EvalError Integer
floatToInteger fun r fp =
  do rat <- floatToRational fun fp
     pure case r of
            NearEven -> round rat
            NearAway -> if rat > 0 then ceiling rat else floor rat
            ToPosInf -> ceiling rat
            ToNegInf -> floor rat
            ToZero   -> truncate rat
            _        -> panic "fpCvtToInteger"
                              ["Unexpected rounding mode", show r]


floatFromBits :: 
  Integer {- ^ Exponent width -} ->
  Integer {- ^ Precision widht -} ->
  Integer {- ^ Raw bits -} ->
  BF
floatFromBits e p bv = BF { bfValue = bfFromBits (fpOpts e p NearEven) bv 
                          , bfExpWidth = e, bfPrecWidth = p }


-- | Turn a float into raw bits.
-- @NaN@ is represented as a positive "quiet" @NaN@
-- (most significant bit in the significand is set, the rest of it is 0)
floatToBits :: Integer -> Integer -> BigFloat -> Integer
floatToBits e p bf = bfToBits (fpOpts e p NearEven) bf
