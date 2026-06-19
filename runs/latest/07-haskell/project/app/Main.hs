{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (SomeException, catch)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Char8 as BS8
import Data.Char (isDigit)
import Data.List (sortBy)
import qualified Data.Map.Strict as Map
import Data.Scientific (floatingOrInteger, toRealFloat)
import qualified Data.Text as T
import qualified Data.Vector as Vector
import Data.Time.Calendar (Day, fromGregorianValid)
import Data.Time.Clock (getCurrentTime)
import Data.Time.LocalTime (getCurrentTimeZone, localDay, utcToLocalTime)
import Network.HTTP.Client
  ( ManagerSettings
  , Response
  , httpLbs
  , method
  , newManager
  , parseRequest
  , responseBody
  , responseStatus
  , responseTimeout
  , responseTimeoutMicro
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode, statusMessage)
import Numeric (showEFloat, showFFloat)
import System.Environment (getArgs, getProgName)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

data Summary = Summary
  { summaryUserId :: Aeson.Value
  , summaryCompleted :: !Int
  , summaryMissed :: !Int
  }

main :: IO ()
main = do
  args <- getArgs
  case args of
    [url] -> run url `catch` reportException
    _ -> do
      prog <- getProgName
      hPutStrLn stderr ("usage: " <> prog <> " <todos-url>")
      exitFailure

run :: String -> IO ()
run url = do
  response <- httpGet url
  let status = responseStatus response
      code = statusCode status
      reason = BS8.unpack (statusMessage status)
  if code < 200 || code >= 300
    then failWith ("bad status: " <> show code <> if null reason then "" else " " <> reason)
    else pure ()

  todos <- case Aeson.eitherDecode (responseBody response) of
    Right value -> pure value
    Left message -> failWith message
  today <- todayLocal
  summaries <- foldTodos today todos
  let rows = sortBy compareSummary (Map.elems summaries)
  putStrLn "USER  COMPLETED  MISSED"
  mapM_ printRow rows

reportException :: SomeException -> IO ()
reportException err = failWith (show err)

failWith :: String -> IO a
failWith message = do
  hPutStrLn stderr message
  exitFailure

httpGet :: String -> IO (Response LBS.ByteString)
httpGet url = do
  request <- parseRequest url
  manager <- newManager settings
  httpLbs request { method = "GET", responseTimeout = responseTimeoutMicro (10 * 1000 * 1000) } manager
  where
    settings :: ManagerSettings
    settings = tlsManagerSettings

foldTodos :: Day -> Aeson.Value -> IO (Map.Map String Summary)
foldTodos today (Aeson.Array todos) =
  Vector.foldM' addTodo Map.empty todos
  where
    addTodo byUser todo = do
      userId <- required todo "userId"
      completed <- required todo "completed"
      dueDate <- required todo "dueDate"
      let key = jsonKey userId
          current = Map.findWithDefault (Summary userId 0 0) key byUser
      updated <-
        if asBoolean completed
          then pure current { summaryCompleted = summaryCompleted current + 1 }
          else do
            due <- parseDateOnlyInLocalTime (asText dueDate)
            pure
              current
                { summaryMissed =
                    summaryMissed current + if due < today then 1 else 0
                }
      pure (Map.insert key updated byUser)
foldTodos _ _ = failWith "expected JSON array"

required :: Aeson.Value -> T.Text -> IO Aeson.Value
required (Aeson.Object object) field =
  case KeyMap.lookup (AesonKey.fromText field) object of
    Just value -> pure value
    Nothing -> failWith ("key '" <> T.unpack field <> "' not found")
required _ field = failWith ("key '" <> T.unpack field <> "' not found")

jsonKey :: Aeson.Value -> String
jsonKey = BS8.unpack . LBS.toStrict . Aeson.encode

displayValue :: Aeson.Value -> String
displayValue (Aeson.String value) = T.unpack value
displayValue (Aeson.Number value) =
  case floatingOrInteger value :: Either Double Integer of
    Right integer -> show integer
    Left double -> cppDefaultDoubleString double
displayValue (Aeson.Bool value) = if value then "true" else "false"
displayValue Aeson.Null = ""
displayValue value = jsonKey value

asBoolean :: Aeson.Value -> Bool
asBoolean (Aeson.Bool value) = value
asBoolean (Aeson.String "true") = True
asBoolean (Aeson.Number 1) = True
asBoolean _ = False

asText :: Aeson.Value -> String
asText (Aeson.String value) = T.unpack value
asText (Aeson.Number value) =
  case floatingOrInteger value :: Either Double Integer of
    Right integer -> show integer
    Left double -> cppDefaultDoubleString double
asText (Aeson.Bool value) = if value then "true" else "false"
asText Aeson.Null = ""
asText value = jsonKey value

compareSummary :: Summary -> Summary -> Ordering
compareSummary a b =
  compare (summaryCompleted b) (summaryCompleted a)
    <> compare (summaryMissed b) (summaryMissed a)
    <> compareUserId (summaryUserId a) (summaryUserId b)

compareUserId :: Aeson.Value -> Aeson.Value -> Ordering
compareUserId (Aeson.Number a) (Aeson.Number b) =
  compare (toRealFloat a :: Double) (toRealFloat b :: Double)
compareUserId (Aeson.String a) (Aeson.String b) = compare a b
compareUserId (Aeson.Bool a) (Aeson.Bool b) = compare a b
compareUserId a b = compare (jsonKey a) (jsonKey b)

cppDefaultDoubleString :: Double -> String
cppDefaultDoubleString value
  | isNaN value = "nan"
  | isInfinite value = if value > 0 then "inf" else "-inf"
  | absValue /= 0.0 && (absValue < 0.0001 || absValue >= 1000000.0) =
      formatScientific value
  | otherwise =
      trimFraction (showFFloat (Just 5) value "")
  where
    absValue = abs value

formatScientific :: Double -> String
formatScientific value =
  normalizeExponent (lowerE (trimMantissa rendered))
  where
    rendered = showEFloat (Just 5) value ""

trimMantissa :: String -> String
trimMantissa input =
  case break (== 'e') input of
    (mantissa, exponentPart) -> trimFraction mantissa <> exponentPart

lowerE :: String -> String
lowerE = map (\c -> if c == 'E' then 'e' else c)

normalizeExponent :: String -> String
normalizeExponent input =
  case break (== 'e') input of
    (_, "") -> input
    (mantissa, _ : exponentPart) ->
      let (sign, digits) =
            case exponentPart of
              '+' : rest -> ("+", rest)
              '-' : rest -> ("-", rest)
              rest -> ("+", rest)
          stripped = dropLeadingZeros digits
       in mantissa <> "e" <> sign <> stripped

dropLeadingZeros :: String -> String
dropLeadingZeros digits =
  case dropWhile (== '0') digits of
    "" -> "0"
    rest -> rest

trimFraction :: String -> String
trimFraction input =
  case break (== '.') input of
    (_, "") -> input
    (whole, _ : frac) ->
      let trimmed = reverse (dropWhile (== '0') (reverse frac))
       in if null trimmed then whole else whole <> "." <> trimmed

parseDateOnlyInLocalTime :: String -> IO Day
parseDateOnlyInLocalTime value = do
  let shapeOk =
        length value == 10
          && value !! 4 == '-'
          && value !! 7 == '-'
          && all digitAt [0 .. 9]
      digitAt index = index == 4 || index == 7 || isDigit (value !! index)
  if not shapeOk
    then failWith (parseErrorMessage value)
    else do
      let year = read (take 4 value)
          month = read (take 2 (drop 5 value))
          day = read (drop 8 value)
      case fromGregorianValid year month day of
        Just parsed -> pure parsed
        Nothing -> failWith (parseErrorMessage value)

parseErrorMessage :: String -> String
parseErrorMessage value =
  "parsing time \"" <> value <> "\" as \"2006-01-02\": cannot parse \"" <> value <> "\" as \"2006\""

todayLocal :: IO Day
todayLocal = do
  now <- getCurrentTime
  zone <- getCurrentTimeZone
  pure (localDay (utcToLocalTime zone now))

printRow :: Summary -> IO ()
printRow row =
  putStrLn
    ( padRight 5 (displayValue (summaryUserId row))
        <> " "
        <> padRight 10 (show (summaryCompleted row))
        <> " "
        <> show (summaryMissed row)
    )

padRight :: Int -> String -> String
padRight width value =
  value <> replicate (max 0 (width - length value)) ' '
