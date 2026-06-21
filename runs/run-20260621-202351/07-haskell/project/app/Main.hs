module Main where

import Control.Exception (SomeException, catch)
import Control.Monad (when)
import Data.Bits (shiftL)
import Data.Char (chr, isDigit, ord)
import Data.List (find, sortBy)
import Data.Maybe (fromMaybe)
import Data.Time.Calendar (Day, fromGregorian, gregorianMonthLength)
import Data.Time.LocalTime (getZonedTime, localDay, zonedTimeToLocalTime)
import Numeric (readSigned, readFloat)
import System.Environment (getArgs)
import System.Exit (ExitCode(..), exitFailure)
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)
import Text.Printf (printf)

data Type = TUndefined | TNull | TBool | TNumber | TString | TArray | TObject
  deriving (Eq, Show)

data Value
  = VUndefined
  | VNull
  | VBool Bool
  | VNumber Double
  | VString String
  | VArray [Value]
  | VObject [Field]
  deriving (Eq, Show)

data Field = Field String Value
  deriving (Eq, Show)

valueType :: Value -> Type
valueType VUndefined = TUndefined
valueType VNull = TNull
valueType (VBool _) = TBool
valueType (VNumber _) = TNumber
valueType (VString _) = TString
valueType (VArray _) = TArray
valueType (VObject _) = TObject

data Parser = Parser
  { inputText :: String
  , inputPos :: Int
  }

failMsg :: String -> Either String a
failMsg = Left

parseJson :: String -> Either String Value
parseJson s = do
  (v, p1) <- parseValue (skipWs (Parser s 0))
  let p2 = skipWs p1
  if inputPos p2 /= length s
    then failMsg ("unexpected token at '" ++ [s !! inputPos p2] ++ "'")
    else Right v

skipWs :: Parser -> Parser
skipWs p
  | inputPos p < length (inputText p)
  , let c = inputText p !! inputPos p
  , c == ' ' || c == '\n' || c == '\r' || c == '\t' = skipWs p { inputPos = inputPos p + 1 }
  | otherwise = p

peekChar :: Parser -> Either String Char
peekChar p
  | inputPos p >= length (inputText p) = failMsg "unexpected end of input"
  | otherwise = Right (inputText p !! inputPos p)

consume :: Char -> Parser -> (Bool, Parser)
consume c p
  | inputPos p < length (inputText p) && inputText p !! inputPos p == c =
      (True, p { inputPos = inputPos p + 1 })
  | otherwise = (False, p)

expect :: Char -> Parser -> Either String Parser
expect c p =
  let (ok, p1) = consume c p
  in if ok then Right p1 else failMsg ("expected '" ++ [c] ++ "'")

parseValue :: Parser -> Either String (Value, Parser)
parseValue p0 = do
  let p = skipWs p0
  c <- peekChar p
  case c of
    'n' -> literal "null" p >>= \p1 -> Right (VNull, p1)
    't' -> literal "true" p >>= \p1 -> Right (VBool True, p1)
    'f' -> literal "false" p >>= \p1 -> Right (VBool False, p1)
    '"' -> do
      (s, p1) <- parseString p
      Right (VString s, p1)
    '[' -> parseArray p
    '{' -> parseObject p
    _ -> parseNumber p

literal :: String -> Parser -> Either String Parser
literal word p
  | take (length word) (drop (inputPos p) (inputText p)) == word =
      Right p { inputPos = inputPos p + length word }
  | otherwise = failMsg "unexpected token"

parseHex4 :: Parser -> Either String (Int, Parser)
parseHex4 p0
  | inputPos p0 + 4 > length (inputText p0) = failMsg "invalid unicode escape"
  | otherwise = go (0 :: Int) 0 p0
  where
    go 4 acc p = Right (acc, p)
    go i acc p =
      let c = inputText p !! inputPos p
          p1 = p { inputPos = inputPos p + 1 }
      in if isHex c
           then go (i + 1) ((acc `shiftL` 4) + hexVal c) p1
           else failMsg "invalid unicode escape"
    isHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
    hexVal c
      | c >= '0' && c <= '9' = ord c - ord '0'
      | c >= 'a' && c <= 'f' = ord c - ord 'a' + 10
      | otherwise = ord c - ord 'A' + 10

parseString :: Parser -> Either String (String, Parser)
parseString p0 = do
  p1 <- expect '"' p0
  go [] p1
  where
    go acc p
      | inputPos p >= length (inputText p) = failMsg "unterminated string"
      | otherwise =
          let c = inputText p !! inputPos p
              pNext = p { inputPos = inputPos p + 1 }
          in case c of
              '"' -> Right (reverse acc, pNext)
              _ | ord c < 0x20 -> failMsg "control character in string"
              '\\' ->
                if inputPos pNext >= length (inputText pNext)
                  then failMsg "invalid escape"
                  else
                    let esc = inputText pNext !! inputPos pNext
                        pEsc = pNext { inputPos = inputPos pNext + 1 }
                    in case esc of
                        '"' -> go ('"' : acc) pEsc
                        '\\' -> go ('\\' : acc) pEsc
                        '/' -> go ('/' : acc) pEsc
                        'b' -> go ('\b' : acc) pEsc
                        'f' -> go ('\f' : acc) pEsc
                        'n' -> go ('\n' : acc) pEsc
                        'r' -> go ('\r' : acc) pEsc
                        't' -> go ('\t' : acc) pEsc
                        'u' -> do
                          (cp0, pHex) <- parseHex4 pEsc
                          (cp, pFinal) <-
                            if cp0 >= 0xD800 && cp0 <= 0xDBFF
                              then do
                                when (inputPos pHex + 6 > length (inputText pHex)
                                      || inputText pHex !! inputPos pHex /= '\\'
                                      || inputText pHex !! (inputPos pHex + 1) /= 'u') $
                                  failMsg "invalid unicode surrogate"
                                let pLowStart = pHex { inputPos = inputPos pHex + 2 }
                                (low, pLow) <- parseHex4 pLowStart
                                when (low < 0xDC00 || low > 0xDFFF) $
                                  failMsg "invalid unicode surrogate"
                                Right (0x10000 + ((cp0 - 0xD800) `shiftL` 10) + (low - 0xDC00), pLow)
                              else Right (cp0, pHex)
                          go (chr cp : acc) pFinal
                        _ -> failMsg "invalid escape"
              _ -> go (c : acc) pNext

parseNumber :: Parser -> Either String (Value, Parser)
parseNumber p0 =
  let s = inputText p0
      begin = inputPos p0
      p1 = if begin < length s && (s !! begin == '+' || s !! begin == '-')
             then p0 { inputPos = begin + 1 }
             else p0
      p2 = consumeDigits p1
      p3 = if inputPos p2 < length s && s !! inputPos p2 == '.'
             then consumeDigits p2 { inputPos = inputPos p2 + 1 }
             else p2
      p4 =
        if inputPos p3 < length s && (s !! inputPos p3 == 'e' || s !! inputPos p3 == 'E')
          then
            let save = inputPos p3
                pE0 = p3 { inputPos = save + 1 }
                pE1 = if inputPos pE0 < length s && (s !! inputPos pE0 == '+' || s !! inputPos pE0 == '-')
                         then pE0 { inputPos = inputPos pE0 + 1 }
                         else pE0
                expBegin = inputPos pE1
                pE2 = consumeDigits pE1
            in if expBegin == inputPos pE2 then p3 { inputPos = save } else pE2
          else p3
      end = inputPos p4
  in if begin == end || (end == begin + 1 && (s !! begin == '+' || s !! begin == '-'))
       then failMsg "unexpected token"
       else case readsDouble (take (end - begin) (drop begin s)) of
              Just n -> Right (VNumber n, p4)
              Nothing -> failMsg "unexpected token"
  where
    consumeDigits p
      | inputPos p < length (inputText p) && isDigit (inputText p !! inputPos p) =
          consumeDigits p { inputPos = inputPos p + 1 }
      | otherwise = p
    readsDouble x =
      case readSigned readFloat x of
        [(n, "")] -> Just n
        _ -> Nothing

parseArray :: Parser -> Either String (Value, Parser)
parseArray p0 = do
  p1 <- expect '[' p0
  let p2 = skipWs p1
      (closed, p3) = consume ']' p2
  if closed
    then Right (VArray [], p3)
    else go [] p2
  where
    go acc p = do
      (v, p1) <- parseValue p
      let p2 = skipWs p1
          (closed, p3) = consume ']' p2
      if closed
        then Right (VArray (reverse (v : acc)), p3)
        else do
          p4 <- expect ',' p2
          go (v : acc) p4

parseObject :: Parser -> Either String (Value, Parser)
parseObject p0 = do
  p1 <- expect '{' p0
  let p2 = skipWs p1
      (closed, p3) = consume '}' p2
  if closed
    then Right (VObject [], p3)
    else go [] p2
  where
    go fields p = do
      (key, pKey) <- parseString (skipWs p)
      pColon <- expect ':' (skipWs pKey)
      (val, pVal) <- parseValue pColon
      let fields' = addOrReplace key val fields
          pAfter = skipWs pVal
          (closed, pClosed) = consume '}' pAfter
      if closed
        then Right (VObject fields', pClosed)
        else do
          pComma <- expect ',' pAfter
          go fields' pComma

addOrReplace :: String -> Value -> [Field] -> [Field]
addOrReplace k v [] = [Field k v]
addOrReplace k v (Field k0 v0 : xs)
  | k == k0 = Field k v : xs
  | otherwise = Field k0 v0 : addOrReplace k v xs

jsonStringEscape :: String -> String
jsonStringEscape s = '"' : concatMap esc s ++ "\""
  where
    esc c = case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\b' -> "\\b"
      '\f' -> "\\f"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      _ | ord c < 0x20 -> printf "\\u%04x" (ord c)
        | otherwise -> [c]

minLongDouble :: Double
minLongDouble = -9223372036854775808.0

maxLongDouble :: Double
maxLongDouble = 9223372036854775808.0

numberIsInteger :: Double -> Bool
numberIsInteger n =
  not (isNaN n) && not (isInfinite n) && fromIntegral (floor n :: Integer) == n
    && n >= minLongDouble
    && n <= maxLongDouble

numberToString :: Double -> String
numberToString n
  | numberIsInteger n && n >= maxLongDouble = "9223372036854775807"
  | numberIsInteger n && n <= minLongDouble = "-9223372036854775808"
  | numberIsInteger n = show (truncate n :: Integer)
  | otherwise = printf "%.15g" n

jsString :: Value -> String
jsString v = case v of
  VUndefined -> "undefined"
  VNull -> "null"
  VBool b -> if b then "true" else "false"
  VString s -> s
  VNumber n -> numberToString n
  VArray _ -> pyRepr v
  VObject _ -> pyRepr v

pyListStr :: [Value] -> String
pyListStr xs = "[" ++ joinWith ", " (map pyRepr xs) ++ "]"

pyHashStr :: [Field] -> String
pyHashStr fs = "{" ++ joinWith ", " (map fieldStr fs) ++ "}"
  where fieldStr (Field k v) = pyRepr (VString k) ++ ": " ++ pyRepr v

pyRepr :: Value -> String
pyRepr v = case v of
  VUndefined -> "undefined"
  VNull -> "None"
  VBool b -> if b then "True" else "False"
  VNumber n -> numberToString n
  VString s -> jsonStringEscape s
  VArray xs -> pyListStr xs
  VObject fs -> pyHashStr fs

pyStr :: Value -> String
pyStr v = case v of
  VNull -> "None"
  VBool b -> if b then "True" else "False"
  VArray xs -> pyListStr xs
  VObject fs -> pyHashStr fs
  _ -> jsString v

jsJsonStringify :: Value -> String
jsJsonStringify v = case v of
  VUndefined -> "undefined"
  VNull -> "null"
  VBool b -> if b then "true" else "false"
  VNumber n -> numberToString n
  VString s -> jsonStringEscape s
  VArray xs -> "[" ++ joinWith "," (map jsJsonStringify xs) ++ "]"
  VObject fs -> "{" ++ joinWith "," (map fieldStr fs) ++ "}"
  where fieldStr (Field k val) = jsonStringEscape k ++ ":" ++ jsJsonStringify val

pythonTruthy :: Value -> Bool
pythonTruthy v = case v of
  VUndefined -> True
  VNull -> False
  VBool b -> b
  VNumber n -> n /= 0.0
  VString s -> not (null s)
  VArray xs -> not (null xs)
  VObject fs -> not (null fs)

objectGet :: Value -> String -> Maybe Value
objectGet (VObject fs) key = case find (\(Field k _) -> k == key) fs of
  Just (Field _ v) -> Just v
  Nothing -> Nothing
objectGet _ _ = Nothing

parseDateOnly :: Value -> Either String Day
parseDateOnly v =
  let txt = jsString v
      shape = length txt == 10
           && all isDigit (take 4 txt)
           && txt !! 4 == '-'
           && all isDigit (take 2 (drop 5 txt))
           && txt !! 7 == '-'
           && all isDigit (drop 8 txt)
  in if not shape
       then failMsg ("parsing time " ++ jsJsonStringify v ++ " as \"2006-01-02\": cannot parse date")
       else
         let year = read (take 4 txt) :: Integer
             month = read (take 2 (drop 5 txt)) :: Int
             day = read (drop 8 txt) :: Int
         in if (year >= 0 && year <= 99) || month < 1 || month > 12 || day < 1 || day > daysInMonth year month
              then failMsg ("parsing time " ++ jsJsonStringify v ++ ": day out of range")
              else Right (fromGregorian year month day)

daysInMonth :: Integer -> Int -> Int
daysInMonth y m
  | m < 1 || m > 12 = 0
  | otherwise = gregorianMonthLength y m

canonicalKey :: Value -> String
canonicalKey = jsJsonStringify

data Summary = Summary
  { summaryUserId :: Value
  , summaryCompleted :: Int
  , summaryMissed :: Int
  } deriving (Eq, Show)

data PyKey = PyKey Int Double String
  deriving (Eq, Show)

pyKey :: Value -> PyKey
pyKey v = case v of
  VNull -> PyKey 0 0.0 ""
  VBool b -> PyKey 1 (if b then 1.0 else 0.0) ""
  VNumber n -> PyKey 1 n ""
  VString s -> PyKey 2 0.0 s
  _ -> PyKey 3 0.0 (jsString v)

comparePyKey :: Value -> Value -> Ordering
comparePyKey a b =
  let PyKey ga na ta = pyKey a
      PyKey gb nb tb = pyKey b
  in case compare ga gb of
       EQ | ga == 1 && na /= nb -> compare na nb
          | otherwise -> compareJavaString ta tb
       other -> other

ljust :: String -> Int -> String
ljust s width
  | javaLength s >= width = s
  | otherwise = s ++ replicate (width - javaLength s) ' '

javaLength :: String -> Int
javaLength = sum . map (\c -> if ord c > 0xFFFF then 2 else 1)

compareJavaString :: String -> String -> Ordering
compareJavaString a b = compare (concatMap utf16Units a) (concatMap utf16Units b)
  where
    utf16Units c
      | ord c <= 0xFFFF = [ord c]
      | otherwise =
          let x = ord c - 0x10000
          in [0xD800 + (x `div` 0x400), 0xDC00 + (x `mod` 0x400)]

fetchJson :: String -> IO (Either String Value)
fetchJson url = do
  (code, out, err) <- readProcessWithExitCode "curl"
    [ "--silent"
    , "--show-error"
    , "--include"
    , "--max-time", "10"
    , "--connect-timeout", "10"
    , url
    ] ""
  case code of
    ExitSuccess ->
      let (status, reason, body) = splitHttpResponse out
      in case status of
          Just n | n >= 200 && n < 300 ->
            pure (parseJson body)
          Just n -> pure (Left ("bad status: " ++ show n ++ if null reason then "" else " " ++ reason))
          Nothing -> pure (Left "bad status: 000")
    ExitFailure _ ->
      pure (Left (trimTrailingNewline err))

splitHttpResponse :: String -> (Maybe Int, String, String)
splitHttpResponse s =
  let (header, rest) = breakHeaderBody s
      statusLine = takeWhile (/= '\r') (takeWhile (/= '\n') header)
  in (parseStatus statusLine, parseReason statusLine, rest)

breakHeaderBody :: String -> (String, String)
breakHeaderBody s =
  case findSeparator "\r\n\r\n" s of
    Just i -> (take i s, drop (i + 4) s)
    Nothing -> case findSeparator "\n\n" s of
      Just i -> (take i s, drop (i + 2) s)
      Nothing -> (s, "")

findSeparator :: String -> String -> Maybe Int
findSeparator needle haystack = go 0 haystack
  where
    go _ [] = Nothing
    go i xs
      | needle `prefixOf` xs = Just i
    go i (_:xs) = go (i + 1) xs
    prefixOf p x = take (length p) x == p

parseStatus :: String -> Maybe Int
parseStatus statusLine =
  case words statusLine of
    ("HTTP/1.0":x:_) | all isDigit x -> Just (read x)
    ("HTTP/1.1":x:_) | all isDigit x -> Just (read x)
    ("HTTP/2":x:_) | all isDigit x -> Just (read x)
    ("HTTP/3":x:_) | all isDigit x -> Just (read x)
    _ -> Nothing

parseReason :: String -> String
parseReason statusLine =
  case words statusLine of
    (_:_:rest) -> unwords rest
    _ -> ""

trimTrailingNewline :: String -> String
trimTrailingNewline = reverse . dropWhile (== '\n') . reverse

processTodos :: Day -> Value -> Either String String
processTodos today todos = do
  rowsMap <- case todos of
    VArray xs -> foldl step (Right []) xs
    _ -> Right []
  let rows = sortBy compareSummary rowsMap
  Right $ "USER  COMPLETED  MISSED\n" ++ concatMap renderRow rows
  where
    step :: Either String [Summary] -> Value -> Either String [Summary]
    step accE todo = do
      acc <- accE
      let userId = fromMaybe VUndefined (objectGet todo "userId")
          completed = fromMaybe VUndefined (objectGet todo "completed")
      if pythonTruthy completed
        then Right (adjustSummary userId (\s -> s { summaryCompleted = summaryCompleted s + 1 }) acc)
        else do
          let dueValue = fromMaybe VUndefined (objectGet todo "dueDate")
          due <- parseDateOnly dueValue
          if due < today
            then Right (adjustSummary userId (\s -> s { summaryMissed = summaryMissed s + 1 }) acc)
            else Right (adjustSummary userId id acc)

    adjustSummary userId f [] = [f (Summary userId 0 0)]
    adjustSummary userId f (s:ss)
      | canonicalKey (summaryUserId s) == canonicalKey userId = f s : ss
      | otherwise = s : adjustSummary userId f ss

    compareSummary a b =
      case compare (summaryCompleted b) (summaryCompleted a) of
        EQ -> case compare (summaryMissed b) (summaryMissed a) of
          EQ -> comparePyKey (summaryUserId a) (summaryUserId b)
          other -> other
        other -> other

    renderRow s =
      ljust (pyStr (summaryUserId s)) 5
      ++ " "
      ++ ljust (show (summaryCompleted s)) 10
      ++ " "
      ++ show (summaryMissed s)
      ++ "\n"

joinWith :: String -> [String] -> String
joinWith _ [] = ""
joinWith _ [x] = x
joinWith sep (x:xs) = x ++ sep ++ joinWith sep xs

main :: IO ()
main = do
  args <- getArgs
  result <- case args of
    [url] -> (do
      fetched <- fetchJson url
      today <- localDay . zonedTimeToLocalTime <$> getZonedTime
      pure (fetched >>= processTodos today)
      ) `catch` (\e -> pure (Left (show (e :: SomeException))))
    _ -> pure (Left "usage: TodoReport <todos-url>")
  case result of
    Right out -> putStr out
    Left msg -> hPutStrLn stderr msg >> exitFailure
