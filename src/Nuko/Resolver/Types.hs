module Nuko.Resolver.Types (
  MonadResolver,
  makePath,
  resolveName,
  addGlobal,
  resolvePath,
  findInSpace,
) where

import Nuko.Resolver.Occourence  (lookupEnv, OccName(..), NameKind, findAltKeyValue)
import Nuko.Resolver.Environment (LocalNS(..), NameSpace(..), Label (..), setUsage, Visibility (Private, Public), currentNamespace, names, addDef)
import Nuko.Resolver.Error       (ResolveError (..))
import Nuko.Resolver.Tree        (Path (Local, Path), ReId(..))
import Nuko.Tree.TopLevel        (ImpPath)
import Nuko.Syntax.Range         (Range(..))
import Nuko.Syntax.Tree          (Name(..))
import Nuko.Utils                (terminate)
import Nuko.Tree (Nm, Re, XPath)

import Relude.Applicative        (Applicative(pure))
import Relude.Monad              (MonadState (get, put), Maybe (..), fromMaybe, gets)
import Relude.Bool               (Bool (True))
import Relude.List               (NonEmpty((:|)))
import Relude.Monoid             (Endo, Semigroup ((<>)))
import Relude.String             (Text)
import Relude.Container          (One(one))
import Relude                    (Foldable (foldr), ($), (<$>), Alternative ((<|>)), Functor ((<$), fmap), ($>), (.))

import Control.Monad.Import      (MonadImport)
import Control.Monad.Chronicle   (MonadChronicle)
import Lens.Micro.Platform       (view)

import qualified Nuko.Resolver.Occourence as Occ
import qualified Nuko.Syntax.Tree         as Syntax
import qualified Data.HashMap.Strict as HashMap

-- | The main monad for the resolution. It's not necessary
-- in the type checker because the MonadState LocalNS is only
-- needed for the resolver.

type MonadResolver m =
  ( MonadImport NameSpace m
  , MonadState LocalNS m
  , MonadChronicle (Endo [ResolveError]) m
  )

makePath :: ImpPath Nm -> (Text, Range)
makePath (x :| xs) =
  foldr (\a (info, loc) -> (info <> "." <> a.text, loc <> a.range))
        (x.text, x.range)
        xs

resolveName :: MonadResolver m => NameKind -> Range -> Text -> m Path
resolveName kind' loc info = do
    let name = OccName info kind'
    env <- get
    fromMaybe (terminate (CannotFindInModule (one (name.kind)) Nothing name.occName loc)) $
          pure (Local (ReId name.occName loc))                 <$  lookupEnv name env._currentNamespace._names
      <|> (\env' -> put env' $> Local (ReId name.occName loc)) <$> setUsage env name True
      <|> resolveAmbiguity                                     <$> lookupEnv name env._openedNames
  where
    resolveAmbiguity :: MonadResolver m => Label -> m Path
    resolveAmbiguity = \case
      (Ambiguous refs other) -> terminate (AmbiguousNames refs other)
      (Single ref mod')      -> pure (Path mod' (ReId ref loc) loc)

findInSpace :: MonadResolver m => NameSpace -> Range -> Text -> NonEmpty NameKind -> m OccName
findInSpace space loc name occs =
    case findAltKeyValue (fmap (OccName name) occs) space._names of
      Just (res, Private) -> terminate (IsPrivate res.kind name loc)
      Just (res, Public)  -> pure res
      Nothing             -> terminate (CannotFindInModule occs (Just space._modName) name loc)

getModule :: MonadResolver m => Range -> Text -> m NameSpace
getModule loc name = do
  module' <- gets (HashMap.lookup name . _openedModules)
  case module' of
    Just res -> pure res
    Nothing  -> terminate (CannotFindModule name loc)

resolvePath :: MonadResolver m => NameKind -> XPath Nm -> m (XPath Re)
resolvePath nameKind (Syntax.Path []  (Name info loc) _) = resolveName nameKind loc info
resolvePath nameKind (Syntax.Path (x : xs) (Name info loc) loc') = do
  let (path, modRange') = makePath (x :| xs)
  module' <- getModule modRange' path
  case Occ.lookupEnv (OccName info nameKind) module'._names of
    Just _  -> pure (Path path (ReId info loc) loc')
    Nothing -> terminate (CannotFindInModule (one nameKind) (Just path) info loc)

addGlobal :: MonadResolver m => Range -> OccName -> Visibility -> m ()
addGlobal loc name vs = do
  def <- gets (view (currentNamespace . names))
  case Occ.lookupEnv name  def of
    Just _  -> terminate (AlreadyExistsName name.occName name.kind loc)
    Nothing -> addDef name vs