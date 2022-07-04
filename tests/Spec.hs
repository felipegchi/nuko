import Relude                      (id, ($), Show, Traversable(sequence, traverse), IO, unlines, FilePath, ConvertUtf8(encodeUtf8), ByteString, (.), fst, Bool (..))
import Relude.String               (Text)
import Relude.Monoid               (Semigroup((<>)))
import Relude.Monad                (Monad((>>=)))
import Relude.Functor              (fmap, (<$>))
import Relude.Applicative          (Applicative(pure))

import Data.These                  (These(..))

import Test.Tasty                  (defaultMain, testGroup, TestName, TestTree)
import Test.Tasty.Golden           (findByExtension, goldenVsString)
import System.FilePath             (dropExtension, addExtension)

import Nuko.Tree
import Nuko.Resolver               (resolveProgram)
import Nuko.Syntax.Lexer.Support   (runLexer, Lexer)
import Nuko.Syntax.Lexer           (scan)
import Nuko.Syntax.Lexer.Tokens    (Token(TcEOF))
import Nuko.Syntax.Range           (Ranged (info))
import Nuko.Syntax.Parser          (parseProgram)

import Text.Pretty.Simple          (pShowNoColor)

import Resolver.PreludeImporter    (resolveEntireProgram)
import Pretty.Tree                 (PrettyTree(prettyShowTree))
import Nuko.Typer.Infer
import Nuko.Typer.Types

import qualified Data.ByteString as ByteString
import qualified Data.Text.Lazy as LazyT

scanUntilEnd :: Lexer [Ranged Token]
scanUntilEnd = do
  res <- scan
  case res.info of
    TcEOF -> pure [res]
    _     -> (res :) <$> scanUntilEnd

goldenStr :: FilePath -> FilePath -> Text -> TestTree
goldenStr file golden str = goldenVsString file golden (pure $ encodeUtf8 str)

prettyShow :: Show a => a -> Text
prettyShow item = LazyT.toStrict $ pShowNoColor item

stringifyErr :: Show a => These [a] b -> These [Text] b
stringifyErr (That e) = That e
stringifyErr (This e) = This (fmap prettyShow e)
stringifyErr (These e f) = These (fmap prettyShow e) f

runThat :: Show a =>  (b -> Text) ->  (ByteString -> These [a] b) -> FilePath -> IO TestTree
runThat fn that file = do
  content <- ByteString.readFile $ addExtension file ".nk"
  let golden = addExtension file ".golden"
  pure $ goldenStr file golden $ case that content of
    That e    -> "✓ That\n"  <> fn e
    This e    -> "✗ This\n"  <> unlines (fmap prettyShow e)
    These e f -> "• These\n" <> unlines (fmap prettyShow e) <> "\n" <> fn f

runFile :: FilePath -> IO TestTree
runFile = runThat prettyShowTree (runLexer scanUntilEnd)

runParser :: FilePath -> IO TestTree
runParser = runThat prettyShowTree (runLexer parseProgram)

runResolver :: FilePath -> IO TestTree
runResolver = runThat prettyShowTree $ \content -> stringifyErr (runLexer parseProgram content)
                                    >>= \ast    -> stringifyErr (resolveEntireProgram ast)

runTyper :: FilePath -> IO TestTree
runTyper = runThat id $ \content ->
  let res = stringifyErr (runLexer parseProgram content)
        >>= \ast -> fst <$> stringifyErr (resolveEntireProgram ast)
        >>= \tree -> case tree.letDecls of
                      [(LetDecl _ _ body _ _)] -> printTy <$> stringifyErr (typecheckExpr body)
                      _                        -> That "No body!"
  in res

runTestPath :: TestName -> FilePath -> (FilePath -> IO TestTree) -> IO TestTree
runTestPath name path run = do
  filesNoExt <- fmap dropExtension <$> findByExtension [".nk"] path
  tests <- traverse run filesNoExt
  pure (Test.Tasty.testGroup name tests)

main :: IO ()
main = do
  testTree <- sequence
    [ runTestPath "Lexing" "tests/Suite/lexer" runFile
    , runTestPath "Parsing" "tests/Suite/parser" runParser
    , runTestPath "Resolver" "tests/Suite/resolver" runResolver
    , runTestPath "Typer" "tests/Suite/typer" runTyper ]
  defaultMain $ Test.Tasty.testGroup "Tests" testTree