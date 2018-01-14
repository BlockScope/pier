{-# LANGUAGE DeriveAnyClass #-}
module Development.Pier.Persistent
    ( addPersistent
    , askPersistent
    , askPersistents
    , cleaning
    ) where

import Data.Binary (encode, decodeOrFail)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Development.Shake
import Development.Shake.Classes
import Development.Shake.Rule
import GHC.Generics

newtype PersistentQ question = PersistentQ question
    deriving (Show, Typeable, Eq, Generic, Hashable, Binary, NFData)

newtype PersistentA answer = PersistentA { unPersistentA :: answer }
    deriving (Show, Typeable, Eq, Generic, Hashable, Binary, NFData)

type instance RuleResult (PersistentQ q) = PersistentA (RuleResult q)

addPersistent
    :: (RuleResult q ~ a, ShakeValue q, ShakeValue a)
    => (q -> Action a)
    -> Rules ()
addPersistent act = addBuiltinRule noLint $ \(PersistentQ q) old depsChanged
                    -> case old of
    Just old' | not depsChanged
              , Just val <- decode' old'
                    -> return $ RunResult ChangedNothing old' val
    _ -> do
            rerunIfCleaned
            new <- PersistentA <$> act q
            return $ RunResult
                    (if (old >>= decode') == Just new
                        then ChangedRecomputeSame
                        else ChangedRecomputeDiff)
                    (encode' new)
                    new
    where
        encode' :: Binary a => a -> BS.ByteString
        encode' = BS.concat . LBS.toChunks . encode

        decode' :: Binary a => BS.ByteString -> Maybe a
        decode' b = case decodeOrFail $ LBS.fromChunks [b] of
                        Right (bs,_,x)
                            | LBS.null bs -> Just x
                        _ -> Nothing


askPersistent
    :: (RuleResult q ~ a, ShakeValue q, ShakeValue a)
    => q
    -> Action a
askPersistent question = do
    PersistentA answer <- apply1 $ PersistentQ question
    return answer

askPersistents
    :: (RuleResult q ~ a, ShakeValue q, ShakeValue a)
    => [q]
    -> Action [a]
askPersistents = fmap (map unPersistentA) . apply . map PersistentQ


data Cleaner = Cleaner
    deriving (Show, Typeable, Eq, Generic, Binary, NFData, Hashable)

type instance RuleResult Cleaner = ()

cleaning :: Bool -> Rules ()
cleaning shouldClean = do
    action rerunIfCleaned
    addBuiltinRule noLint $ \Cleaner _ _ ->
        let change = if shouldClean
                        then ChangedRecomputeDiff
                        else ChangedNothing
        in return $ RunResult change BS.empty ()

rerunIfCleaned :: Action ()
rerunIfCleaned = apply1 Cleaner
