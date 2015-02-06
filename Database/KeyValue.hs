-- Simple key value store

module Database.KeyValue ( get
                         , put
                         , delete
                         , initDB
                         , listKeys
                         , closeDB
                         , mergeDataLogs
                         , Config
                         ) where

import           Control.Exception
import qualified Data.ByteString                 as B
import qualified Data.ByteString.Lazy            as BL
import qualified Data.HashTable.IO               as HT
import           Data.Serialize.Get
import           Data.Serialize.Put
import           Database.KeyValue.LogOperations
import           Database.KeyValue.Parsing
import           Database.KeyValue.Timestamp
import           Database.KeyValue.Types
import           System.Directory
import           System.IO

-- Initialize the database
initDB :: Config -> IO KeyValue
initDB cfg = do
    check <- doesDirectoryExist (baseDirectory cfg)
    if not check
      then error "Base directory does not exist."
      else
        do
          hintFileNames <- getFiles hintExt (baseDirectory cfg)
          keysAndValueLocs <- getKeyAndValueLocs hintFileNames
          -- TODO: Add conflict resolution using timestamp
          table <- HT.fromList keysAndValueLocs
          (newHintHandle, newRecordHandle) <- addNewRecord (baseDirectory cfg)
          return (KeyValue newHintHandle newRecordHandle table)

-- Insert a key value in the database
put :: KeyValue -> Key -> Value -> IO ()
put db k v = do
    offset <- hFileSize (currRecordHandle db)
    t <- currentTimestamp
    B.hPut (currRecordHandle db) (runPut (deserializeData k v t))
    B.hPut (currHintHandle db) (runPut (deserializeHint k (offset + 1) t))
    HT.insert (offsetTable db) k (ValueLoc (offset + 1) (currRecordHandle db))
    return ()

-- Get the value of the key
get :: KeyValue -> Key -> IO (Maybe Value)
get db k = do
    maybeRecordInfo <- HT.lookup (offsetTable db) k
    case maybeRecordInfo of
      Nothing -> return Nothing
      (Just recordInfo) -> if rOffset recordInfo == 0
        then
          return Nothing
        else
          do
            hSeek (rHandle recordInfo) AbsoluteSeek (rOffset recordInfo - 1)
            l <- BL.hGetContents (rHandle recordInfo)
            case runGetLazy parseDataLog l of
              Left _ -> return Nothing
              Right v -> return (Just (dValue v))

-- Delete key from database
delete :: KeyValue -> Key -> IO ()
delete db k = do
    HT.delete (offsetTable db) k
    t <- currentTimestamp
    B.hPut (currHintHandle db) (runPut (deserializeHint k 0 t))
    return ()

-- List all keys
listKeys :: KeyValue -> IO [Key]
listKeys db = fmap (map fst) $ (HT.toList . offsetTable) db

closeDB :: KeyValue -> IO ()
closeDB db = do
    hClose (currHintHandle db)
    hClose (currRecordHandle db)
    recordHandles <- fmap (map (rHandle . snd)) ((HT.toList . offsetTable) db)
    mapM_ hClose recordHandles

mergeDataLogs :: FilePath -> IO ()
mergeDataLogs dir = do
    check <- doesDirectoryExist dir
    if not check
      then error "Base directory does not exist."
      else
        do
          hintFiles' <- getFiles hintExt dir
          hintFiles <- evaluate hintFiles'
          currentKeys <- getKeysFromHintFiles hintFiles
          recordFiles' <- getFiles recordExt dir
          recordFiles <- evaluate recordFiles'
          (newHintHandle, newRecordHandle) <- addNewRecord dir
          putKeysFromRecordFiles newHintHandle newRecordHandle currentKeys recordFiles
          hClose newHintHandle
          hClose newRecordHandle
          mapM_ removeFile hintFiles
          mapM_ removeFile recordFiles
