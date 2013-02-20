{-# LANGUAGE OverloadedStrings
           , ScopedTypeVariables
           , DeriveDataTypeable
           , MultiParamTypeClasses #-}
-- | Defines the data model and security policy of posts.
module LBH.MP ( PostId
                , getPostId
                , Post(..), labeledRequestToPost, partiallyFillPost 
                , savePost
                , withLBHPolicy ) where

import           Prelude hiding (lookup)

import           Data.Maybe
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Char8 as S8
import           Data.Typeable
import           Data.Time.Clock (UTCTime)

import           Control.Monad

import           Hails.Data.Hson
import           Hails.Web
import           Hails.Database
import           Hails.Database.Structured
import           Hails.PolicyModule
import           Hails.PolicyModule.DSL
import           Hails.HttpServer.Types

import           LIO
import           LIO.DCLabel

--
-- Posts
--


-- | Post identifiers (@Nothing@ if post is newly create).
type PostId  = Maybe ObjectId

-- | Unsafe post id extrat
getPostId :: Post -> ObjectId
getPostId = fromJust . postId

-- | Data type encoding posts.
data Post = Post { postId          :: PostId
                 , postTitle       :: Text
                 , postOwner       :: UserName
                 , postDescription :: Text
                 , postBody        :: Text
                 , postIsPublic    :: Bool
                 , postDate        :: UTCTime
                 } deriving (Show, Eq)

-- | The type constructor should not be exported to avoid leaking
-- the privilege.
data LBHPolicy = LBHPolicyTCB DCPriv
                  deriving Typeable

instance PolicyModule LBHPolicy where
   initPolicyModule priv =  do
     setPolicy priv $ do
      -- Anybody can read and write to DB
      -- Only MP can administer DB
       database $ do
         readers ==> anybody
         writers ==> anybody
         admins  ==> this
       collection "posts" $ do
       -- Anybody can write a new post
       -- Only owner of the post can modify it
       -- Post is publicly readable when the owner indicates as such
         access $ do
           readers ==> anybody
           writers ==> anybody
         clearance $ do
           secrecy   ==> this
           integrity ==> anybody
         document $ \doc -> do
           let (Just p) = fromDocument doc
               owner = userToPrincipal . postOwner $ p
           readers ==> if postIsPublic p
                         then anybody
                         else this \/ owner
           writers ==> this \/ owner
      --
     return $ LBHPolicyTCB priv
       where this = privDesc priv
             userToPrincipal = principal . S8.pack . T.unpack


instance DCLabeledRecord LBHPolicy Post where
  endorseInstance _ = LBHPolicyTCB noPriv

instance DCRecord Post where
  fromDocument doc = do
    let pid      = lookupObjId "_id" doc
        isPublic =  fromMaybe False $ lookupBool "isPublic" doc
    title        <- lookup "title" doc
    owner        <- lookup "owner" doc
    description  <- lookup "description" doc
    body         <- lookup "body"  doc
    date         <- lookup "date"  doc
    return Post { postId          = pid
                , postTitle       = title
                , postOwner       = owner
                , postDescription = description
                , postBody        = body
                , postDate        = date
                , postIsPublic    = isPublic }
                
  toDocument p = 
    let pid = postId p
        pre = if isJust pid
               then ["_id" -: fromJust pid]
               else []
    in pre ++ [ "title"       -: postTitle p
              , "owner"       -: postOwner p
              , "description" -: postDescription p
              , "body"        -: postBody p
              , "date"        -: postDate p
              , "isPublic"    -: postIsPublic p ]

  recordCollection _ = "posts"

-- | Execute action, restoring the current label.
-- Secrecy of the current label is preserved in the label of the value.
-- The result is partially endorse by the MP's label.
--
-- DO NOT EXPOSE THIS FUNCTION
toLabeledTCB :: DCPriv -> DCLabel -> DC a -> DC (DCLabeled a)
toLabeledTCB privs lgoal act = do
  l0   <- getLabel
  res  <- act
  l1   <- getLabel
  let lendorse = dcLabel dcTrue (toComponent (privDesc privs))
      lgoal' = lgoal `lub` lendorse
            -- effectively use privs in integrity only:
      l1' = l1 `glb` dcLabel dcFalse (toComponent (privDesc privs))
  unless (l1' `canFlowTo` lgoal') $ fail "Invalid usage of toLabeled"
  lres <- labelP privs lgoal' res
  setLabelP privs (partDowngradeP privs l1 l0)
  return lres
   

-- | Convert a labeled reques to  a labeled post, setting the date
labeledRequestToPost :: DCLabeled Request -> DC (DCLabeled Post)
labeledRequestToPost lreq = withPolicyModule $ \(LBHPolicyTCB p) ->
  liftLIO $ toLabeledTCB p (labelOf lreq) $ do
    -- Get labeled document
    ldoc <- labeledRequestToHson lreq
    -- Unlabel request (need time)
    req  <- unlabel lreq
    -- Unlabel document (to add time)
    doc  <- unlabel ldoc
    -- Convert document to record
    fromDocument $ [ "date" -: requestTime req] `merge` doc

-- | Create new record with partially filled fields
partiallyFillPost :: DCLabeled Document -> DC (Maybe (DCLabeled Post))
partiallyFillPost ldoc = withPolicyModule $ \(LBHPolicyTCB p) -> do
  -- Unlabel document
  doc <- unlabel ldoc
  case lookupObjId "_id" doc of
    Nothing -> return Nothing
    Just (_id :: ObjectId) -> do
      -- Lookup existing document:
      mldoc' <- findOne (select ["_id" -: _id] "posts")
      clr <- getClearance
      case mldoc' of
        Just ldoc' | canFlowTo (labelOf ldoc') clr -> do
          res <- liftLIO $ toLabeledTCB p (labelOf ldoc') $ do
            doc' <- unlabel ldoc'
            -- merge new (safe) fields and convert it to a record
            fromDocument $ (safeFields `include` doc) `merge` doc'
          return (Just res)
        _ -> return Nothing
  where safeFields = ["isPublic", "title", "description", "body"]

-- | Save post, by first declassifying it
savePost :: DCLabeled Post -> DC ()
savePost lpost =  withPolicyModule $ \(LBHPolicyTCB privs) -> do
  lpost' <- untaintLabeledP privs l lpost
  saveLabeledRecord lpost'
    where l = dcLabel dcTrue (dcIntegrity . labelOf $ lpost)
  

-- | Execute a database action against the posts DB.
withLBHPolicy :: DBAction a -> DC a
withLBHPolicy act = withPolicyModule $ \(LBHPolicyTCB _) -> act

-- | Get object id (may need to convert from string).
lookupObjId :: Monad m => FieldName -> HsonDocument -> m ObjectId
lookupObjId = lookupTyped 

-- | Get boolean (may need to convert from string).
lookupBool  :: Monad m => FieldName -> HsonDocument -> m Bool
lookupBool = lookupTyped 

-- | Generic lookup with possible type cast
lookupTyped :: (HsonVal a, Read a, Monad m) => FieldName -> HsonDocument -> m a
lookupTyped n d = case lookup n d of
    Just i -> return i
    _ -> case do { s <- lookup n d; maybeRead s } of
          Just i -> return i
          _ -> fail $ "lookupTyped: cannot extract id from " ++ show n
  where maybeRead = fmap fst . listToMaybe . reads