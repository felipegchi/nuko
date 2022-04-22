module Typer.Env
  ( Lvl,
    Name,
    Hole (..),
    Ty (..),
    TyHole,
    Env (..),
    TyperMonad,
    Tracker (..),
    track,
    getTyPos,
    scopeVar,
    scopeVars,
    scopeUp,
    newHole,
    substitute,
    generalize,
    instantiate,
    scopeTy,
    existentialize,
    runEnv,
    named,
    fillHole,
    readHole,
    setHole,
    addTy,
    addCons,
    zonk,
    addField
  )
where

import Typer.Types
import Expr                   (Expr, Typer, Literal, Pattern)
import Data.Foldable          (traverse_)
import Data.IORef             (newIORef, writeIORef)
import Data.Map               (Map)
import GHC.IORef              (readIORef)
import Syntax.Range           (Range)
import Data.Set               (Set)
import Syntax.Tree            (Normal)
import Control.Monad.State    (MonadState, StateT)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Sequence          (Seq ((:|>)))

import qualified Control.Monad.State as State
import qualified Data.Map            as Map
import qualified Data.Text           as Text
import qualified Data.Set            as Set
import qualified Data.Sequence       as Seq
import Control.Monad (when)

-- | Useful to track what the type checker did to achieve an error.
--   It helps a lot when writing error messages.
data Tracker
  = InInferExpr (Expr Normal)
  | InInferTy   (Typer Normal)
  | InInferLit  (Literal Normal)
  | InInferPat  (Pattern Normal)
  | InCheckPat  (Pattern Normal)
  | InInferGen  Range
  | InCheck     (Expr Normal) Ty
  | InUnify     Ty Ty
  | InApply     Ty (Expr Normal)
  deriving Show

-- | Stores all the info about the environment of typing, trackers
--   (that helps a lot with error localization) and some cool numbers
--   to generate new variable names.

debug :: Bool
debug = False

data Env = Env
  { scope     :: Lvl,
    nameGen   :: Int,
    trackers  :: Seq Tracker,

    variables  :: Map Name Ty,
    dataCons   :: Map Name Ty,
    types      :: Map Name Ty,
    fields     :: Map Name Ty,
    namespaces :: Map Name Env,

    debugLvl   :: Int
  }



type TyperMonad m = (MonadState Env m, MonadIO m)

updateTracker :: TyperMonad m => (Seq Tracker -> Seq Tracker) -> m ()
updateTracker f = State.modify (\ctx -> ctx {trackers = f ctx.trackers})

track :: TyperMonad m => Tracker -> m a -> m a
track tracker action = do
    updateTracker (:|> tracker)
    when debug $ do
      lvl <- State.gets debugLvl
      State.modify (\ctx -> ctx { debugLvl = lvl + 1 })
      liftIO $ putStrLn $ replicate (lvl * 3) ' ' ++ show tracker
    res <- action
    updateTracker (removeLeft)
    when debug $ do
      lvl <- State.gets debugLvl
      State.modify (\ctx -> ctx { debugLvl = lvl - 1 })
    pure res
  where
    removeLeft :: Seq a -> Seq a
    removeLeft (a :|> _)   = a
    removeLeft (Seq.Empty) = Seq.empty

-- Scoping and variales

updateVars :: TyperMonad m => (Map Name Ty -> Map Name Ty) -> m ()
updateVars f = State.modify (\ctx -> ctx {variables = f (ctx.variables)})

updateTypes :: TyperMonad m => (Map Name Ty -> Map Name Ty) -> m ()
updateTypes f = State.modify (\ctx -> ctx {types = f (ctx.types)})

updateCons :: TyperMonad m => (Map Name Ty -> Map Name Ty) -> m ()
updateCons f = State.modify (\ctx -> ctx {dataCons = f (ctx.dataCons)})

updateFields :: TyperMonad m => (Map Name Ty -> Map Name Ty) -> m ()
updateFields f = State.modify (\ctx -> ctx {fields = f (ctx.fields)})

scopeVar :: TyperMonad m => Name -> Ty -> m a -> m a
scopeVar name ty action = do
  oldTy <- State.gets variables
  updateVars (Map.insert name ty)
  act <- action
  updateVars (const oldTy)
  pure act

scopeVars :: TyperMonad m => [(Name, Ty)] -> m a -> m a
scopeVars vars action = do
  oldTy <- State.gets variables
  traverse_ (updateVars . uncurry Map.insert) vars
  act <- action
  updateVars (const oldTy)
  pure act

scopeTy :: TyperMonad m => Name -> Ty -> m a -> m a
scopeTy name ty action = do
  oldTy <- State.gets types
  updateTypes (Map.insert name ty)
  act <- action
  updateTypes (const oldTy)
  pure act

scopeUp :: TyperMonad m => m a -> m a
scopeUp action =
  modScope (+ 1) *> action <* modScope (subtract 1)
  where
    modScope :: TyperMonad m => (Int -> Int) -> m ()
    modScope f = State.modify (\s -> s {scope = f s.scope})

newHole :: TyperMonad m => m TyHole
newHole = do
  scope' <- State.gets scope
  name <- newNamed
  res <- liftIO $ newIORef (Empty name scope')
  pure res

newNamed :: TyperMonad m => m Name
newNamed = do
  name <- State.state (\env -> (Text.pack $ "'" ++ show env.nameGen, env { nameGen = env.nameGen + 1}))
  pure name

addTy :: TyperMonad m => Name -> Ty -> m ()
addTy name ty = updateTypes $ Map.insert name ty

addCons :: TyperMonad m => Name -> Ty -> m ()
addCons name ty = updateCons $ Map.insert name ty

addField:: TyperMonad m => Name -> Ty -> m ()
addField name ty = updateFields $ Map.insert name ty

-- Generalization and instantiation

generalize :: TyperMonad m => Ty -> m Ty
generalize ty = do
    let pos = getTyPos ty
    freeVars <- Set.toList <$> go ty
    pure (foldl (flip $ TyForall pos) ty freeVars)
  where
    go :: TyperMonad m => Ty -> m (Set Name)
    go = \case
      TyRef _ ty'   -> go ty'
      TyRigid _ _ _ -> pure Set.empty
      TyNamed _ _ -> pure Set.empty
      TyFun _ ty' ty'' -> Set.union <$> go ty' <*> go ty''
      TyForall _ _ ty' -> go ty'
      TyHole loc hole -> do
        resHole <- liftIO $ readIORef hole
        case resHole of
          Empty _ hScope -> do
            lvl <- State.gets scope
            if (hScope > lvl) then do
              name <- newNamed
              liftIO $ writeIORef hole (Filled $ TyNamed loc name)
              pure $ Set.singleton name
            else pure Set.empty
          Filled ty' -> go ty'

zonk :: TyperMonad m => Ty -> m Ty
zonk = \case
  TyRef pos ty'   -> TyRef pos <$> zonk ty'
  TyRigid pos name lvl -> pure $ TyRigid pos name lvl
  TyNamed pos name -> pure $ TyNamed pos name
  TyFun pos ty' ty'' -> TyFun pos <$> zonk ty' <*> zonk ty''
  TyForall pos name ty' -> TyForall pos name <$> zonk ty'
  TyHole loc hole -> do
    resHole <- liftIO $ readIORef hole
    case resHole of
      Empty _ _ -> pure (TyHole loc hole)
      Filled ty' -> zonk ty'

instantiate :: TyperMonad m => Ty -> m Ty
instantiate = \case
  (TyForall loc binder body) -> do
    hole <- TyHole loc <$> newHole
    pure (substitute binder hole body)
  other -> pure other

-- Lol i dont want to use the word "skolomize"
existentialize :: TyperMonad m => Ty -> m Ty
existentialize = \case
  (TyForall loc binder body) -> do
    lvl <- State.gets scope
    pure (substitute binder (TyRigid loc binder lvl) body)
  other -> pure other

fillHole :: TyperMonad m => TyHole -> Ty -> m ()
fillHole hole ty = liftIO $ writeIORef hole (Filled ty)

readHole :: TyperMonad m => TyHole -> m (Hole Ty)
readHole = liftIO . readIORef

setHole :: TyperMonad m => TyHole -> Hole Ty -> m ()
setHole hole = liftIO . writeIORef hole

named :: TyperMonad m => Range -> Name -> m Ty
named range name = pure (TyNamed (Just range) name)

runEnv :: StateT Env IO a -> Env -> IO (a, Env)
runEnv action env = State.runStateT action env