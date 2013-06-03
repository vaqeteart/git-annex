{- git-annex assistant webapp types
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

{-# LANGUAGE TypeFamilies, QuasiQuotes, MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell, OverloadedStrings, RankNTypes #-}
{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Assistant.WebApp.Types where

import Assistant.Common
import Assistant.Ssh
import Assistant.Pairing
import Assistant.Types.Buddies
import Utility.NotificationBroadcaster
import Utility.WebApp
import Utility.Yesod
import Logs.Transfer
import Build.SysConfig (packageversion)

import Yesod
import Yesod.Static
import Text.Hamlet
import Data.Text (Text, pack, unpack)
import Network.Socket (HostName)

publicFiles "static"

staticRoutes :: Static
staticRoutes = $(embed "static")

mkYesodData "WebApp" $(parseRoutesFile "Assistant/WebApp/routes")

data WebApp = WebApp
	{ assistantData :: AssistantData
	, secretToken :: Text
	, relDir :: Maybe FilePath
	, getStatic :: Static
	, postFirstRun :: Maybe (IO String)
	, noAnnex :: Bool
	, listenHost ::Maybe HostName
	}

instance Yesod WebApp where
	{- Require an auth token be set when accessing any (non-static) route -}
	isAuthorized _ _ = checkAuthToken secretToken

	{- Add the auth token to every url generated, except static subsite
	 - urls (which can show up in Permission Denied pages). -}
	joinPath = insertAuthToken secretToken excludeStatic
	  where
		excludeStatic [] = True
		excludeStatic (p:_) = p /= "static"

	makeSessionBackend = webAppSessionBackend
	jsLoader _ = BottomOfHeadBlocking

	{- The webapp does not use defaultLayout, so this is only used
	 - for error pages or any other built-in yesod page.
	 - 
	 - This can use static routes, but should use no other routes,
	 - as that would expose the auth token.
	 -}
	defaultLayout content = do
		webapp <- getYesod
		pageinfo <- widgetToPageContent $ do
			addStylesheet $ StaticR css_bootstrap_css
			addStylesheet $ StaticR css_bootstrap_responsive_css
			$(widgetFile "error")
		hamletToRepHtml $(hamletFile $ hamletTemplate "bootstrap")

instance RenderMessage WebApp FormMessage where
	renderMessage _ _ = defaultFormMessage

{- Runs an Annex action from the webapp.
 -
 - When the webapp is run outside a git-annex repository, the fallback
 - value is returned.
 -}
liftAnnexOr :: forall a. a -> Annex a -> Handler a
liftAnnexOr fallback a = ifM (noAnnex <$> getYesod)
	( return fallback
	, liftAssistant $ liftAnnex a
	)

instance LiftAnnex Handler where
	liftAnnex = liftAnnexOr $ error "internal liftAnnex"

instance LiftAnnex (WidgetT WebApp IO) where
	liftAnnex = liftH . liftAnnex

class LiftAssistant m where
	liftAssistant :: Assistant a -> m a

instance LiftAssistant Handler where
	liftAssistant a = liftIO . flip runAssistant a
		=<< assistantData <$> getYesod

instance LiftAssistant (WidgetT WebApp IO) where
	liftAssistant = liftH . liftAssistant

type Form x = MForm Handler (FormResult x, Widget)

data RepoSelector = RepoSelector
	{ onlyCloud :: Bool
	, onlyConfigured :: Bool
	, includeHere :: Bool
	, nudgeAddMore :: Bool
	}
	deriving (Read, Show, Eq)

data RepoListNotificationId = RepoListNotificationId NotificationId RepoSelector
	deriving (Read, Show, Eq)

data RemovableDrive = RemovableDrive 
	{ diskFree :: Maybe Integer
	, mountPoint :: Text
	, driveRepoPath :: Text
	}
	deriving (Read, Show, Eq, Ord)

{- Only needed to work around old-yesod bug that emits a warning message
 - when a route has two parameters. -}
data FilePathAndUUID = FilePathAndUUID FilePath UUID
	deriving (Read, Show, Eq)

instance PathPiece FilePathAndUUID where
	toPathPiece = pack . show
	fromPathPiece = readish . unpack

instance PathPiece RemovableDrive where
	toPathPiece = pack . show
	fromPathPiece = readish . unpack

instance PathPiece SshData where
	toPathPiece = pack . show
	fromPathPiece = readish . unpack

instance PathPiece NotificationId where
	toPathPiece = pack . show
	fromPathPiece = readish . unpack

instance PathPiece AlertId where
	toPathPiece = pack . show
	fromPathPiece = readish . unpack

instance PathPiece Transfer where
	toPathPiece = pack . show
	fromPathPiece = readish . unpack

instance PathPiece PairMsg where
	toPathPiece = pack . show
	fromPathPiece = readish . unpack

instance PathPiece SecretReminder where
	toPathPiece = pack . show
	fromPathPiece = readish . unpack

instance PathPiece UUID where
	toPathPiece = pack . show
	fromPathPiece = readish . unpack

instance PathPiece BuddyKey where
	toPathPiece = pack . show
	fromPathPiece = readish . unpack

instance PathPiece PairKey where
	toPathPiece = pack . show
	fromPathPiece = readish . unpack

instance PathPiece RepoListNotificationId where
	toPathPiece = pack . show
	fromPathPiece = readish . unpack

instance PathPiece RepoSelector where
	toPathPiece = pack . show
	fromPathPiece = readish . unpack

instance PathPiece ThreadName where
	toPathPiece = pack . show
	fromPathPiece = readish . unpack
