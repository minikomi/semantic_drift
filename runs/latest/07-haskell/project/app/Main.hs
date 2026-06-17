{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (SomeException, catch)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as LBS
import Data.Char (isDigit)
import Data.List (sortBy)
import qualified Data.Scientific as Scientific
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as Vector
import Data.Time
  ( Day
  , LocalTime (LocalTime)
  , TimeOfDay (TimeOfDay)
  , UTCTime
  , ZonedTime
  , defaultTimeLocale
  , getZonedTime
  , localTimeToUTC
  , minutesToTimeZone
  , parseTimeM
  , zonedTimeToUTC
  , zonedTimeToLocalTime
  )
import Data.Time.Calendar (fromGregorianValid)
import Network.HTTP.Client
  ( httpLbs
  , method
  , newManager
  , parseRequest
  , responseBody
  , responseStatus
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode, statusMessage)
import System.Environment (getArgs)
import System.Exit (exitWith, ExitCode (ExitFailure, ExitSuccess))
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)
import Text.Printf (printf)

data Summary = Summary
  { summaryUserId :: Aeson.Value
  , summaryCompleted :: !Int
  , summaryMissed :: !Int
  }

main :: IO ()
main = do
  args <- getArgs
  code <- run args `catch` \(err :: SomeException) -> do
    let msg = show err
    putStrLnErr msg
    pure 1
  exitWith $ if code == 0 then ExitSuccess else ExitFailure code

run :: [String] -> IO Int
run [url] = do
  manager <- newManager tlsManagerSettings
  request <- parseRequest url
  response <- httpLbs request { method = "GET" } manager
  let status = responseStatus response
      code = statusCode status
  if code < 200 || code >= 300
    then do
      let reason = TE.decodeUtf8 (statusMessage status)
          suffix = if T.null reason then "" else " " <> T.unpack reason
      putStrLnErr $ "bad status: " <> show code <> suffix
      pure 1
    else do
      todos <- decodeTodos (responseBody response)
      today <- localStartOfToday
      let rows = summarize today todos
      putStrLn "USER  COMPLETED  MISSED"
      mapM_ printSummary rows
      pure 0
run _ = do
  putStrLnErr "usage: ./run.sh <url>"
  pure 2

decodeTodos :: LBS.ByteString -> IO [KeyMap.KeyMap Aeson.Value]
decodeTodos body =
  case Aeson.eitherDecode body of
    Left err -> fail err
    Right values -> pure values

summarize :: UTCTime -> [KeyMap.KeyMap Aeson.Value] -> [Summary]
summarize today todos =
  sortBy compareSummary $ map snd final
  where
    final = foldl' step [] todos

    step acc todo =
      let userId = lookupDefault "userId" todo
          key = stringify userId
          existing = maybe (Summary userId 0 0) id (lookup key acc)
          updated =
            if isTruthy (lookupDefault "completed" todo)
              then existing { summaryCompleted = summaryCompleted existing + 1 }
              else
                let due = parseDateOnly (stringify (lookupDefault "dueDate" todo))
                 in if due < today
                      then existing { summaryMissed = summaryMissed existing + 1 }
                      else existing
       in upsert key updated acc

lookupDefault :: Key.Key -> KeyMap.KeyMap Aeson.Value -> Aeson.Value
lookupDefault key = maybe Aeson.Null id . KeyMap.lookup key

upsert :: String -> Summary -> [(String, Summary)] -> [(String, Summary)]
upsert key summary [] = [(key, summary)]
upsert key summary ((existingKey, existingSummary):rest)
  | key == existingKey = (key, summary) : rest
  | otherwise = (existingKey, existingSummary) : upsert key summary rest

compareSummary :: Summary -> Summary -> Ordering
compareSummary left right =
  compare (summaryCompleted right) (summaryCompleted left)
    <> compare (summaryMissed right) (summaryMissed left)
    <> comparePhpValues (summaryUserId left) (summaryUserId right)

printSummary :: Summary -> IO ()
printSummary summary =
  printf "%-5s %-10d %d\n"
    (stringify (summaryUserId summary))
    (summaryCompleted summary)
    (summaryMissed summary)

isTruthy :: Aeson.Value -> Bool
isTruthy Aeson.Null = False
isTruthy (Aeson.Bool b) = b
isTruthy (Aeson.Number n) = n /= 0
isTruthy value = not (null (stringify value))

stringify :: Aeson.Value -> String
stringify Aeson.Null = ""
stringify (Aeson.Bool True) = "true"
stringify (Aeson.Bool False) = "false"
stringify (Aeson.String text) = T.unpack text
stringify (Aeson.Number n) =
  case Scientific.floatingOrInteger n :: Either Double Integer of
    Right i -> show i
    Left _ -> Scientific.formatScientific Scientific.Generic Nothing n
stringify (Aeson.Array values) = "[" <> joinWith ", " (map stringify (Vector.toList values)) <> "]"
stringify (Aeson.Object object) =
  "{" <> joinWith ", " (map renderPair (KeyMap.toList object)) <> "}"
  where
    renderPair (key, value) = T.unpack (Key.toText key) <> "=" <> stringify value

comparePhpValues :: Aeson.Value -> Aeson.Value -> Ordering
comparePhpValues (Aeson.Number left) (Aeson.Number right) = compare left right
comparePhpValues left right = compare (stringify left) (stringify right)

parseDateOnly :: String -> UTCTime
parseDateOnly value
  | not (looksDateOnly value) =
      error $ "parsing time \"" <> value <> "\" as \"2006-01-02\": cannot parse \"" <> value <> "\" as \"2006\""
  | year < 1 || year > 9999 =
      error $ "year " <> show year <> " is out of range"
  | month < 1 || month > 12 =
      error "month must be in 1..12"
  | otherwise =
      case fromGregorianValid (fromIntegral year) month day of
        Nothing -> error $ "parsing time \"" <> value <> "\": day out of range"
        Just date -> localTimeToUTC utc (LocalTime date midnight)
  where
    year = read (take 4 value) :: Int
    month = read (take 2 (drop 5 value)) :: Int
    day = read (take 2 (drop 8 value)) :: Int
    midnight = TimeOfDay 0 0 0
    utc = minutesToTimeZone 0

looksDateOnly :: String -> Bool
looksDateOnly value =
  length value == 10
    && all isDigit (take 4 value)
    && value !! 4 == '-'
    && all isDigit (take 2 (drop 5 value))
    && value !! 7 == '-'
    && all isDigit (drop 8 value)

localStartOfToday :: IO UTCTime
localStartOfToday = do
  (_exitCode, stdoutText, _stderrText) <- readProcessWithExitCode "date" ["+%Y-%m-%dT00:00:00%z"] ""
  case parseDateOutput (trim stdoutText) of
    Just time -> pure time
    Nothing -> do
      zoned <- getZonedTime
      let day = localDayFromZoned zoned
      pure $ zonedTimeToUTC zoned { zonedTimeToLocalTime = LocalTime day (TimeOfDay 0 0 0) }

parseDateOutput :: String -> Maybe UTCTime
parseDateOutput =
  parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%z"

localDayFromZoned :: ZonedTime -> Day
localDayFromZoned zoned =
  case zonedTimeToLocalTime zoned of
    LocalTime day _ -> day

joinWith :: String -> [String] -> String
joinWith _ [] = ""
joinWith _ [x] = x
joinWith sep (x:xs) = x <> sep <> joinWith sep xs

trim :: String -> String
trim = reverse . dropWhile (`elem` ['\n', '\r', ' ', '\t']) . reverse . dropWhile (`elem` ['\n', '\r', ' ', '\t'])

putStrLnErr :: String -> IO ()
putStrLnErr = hPutStrLn stderr
