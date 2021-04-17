{- 
  Monadic definitional interpreter.
-}
{-# LANGUAGE TemplateHaskell, TypeOperators #-}

module Interpreter(obey, init_gs, init_env) where

import Parsing
import FunSyntax
import FunParser
import Environment
import CState
import TreeUtils

import Data.List (intercalate)

import Data.Label
import Data.Label.Monadic

import Control.Monad
import Control.Monad.State
import Control.Monad.Trans (lift)
import CCExc

import Debug.Trace

----- Helper types -----
type Env          = Environment Value

type Kont         = CC PromptT (State GlobState)
type PromptT      = P2 Value Value
type ProgState    = (Env, GlobState)
type Arg          = String
type Name         = String

-- Patterns in our language are Expressions themselves; see the comment
-- for the `matchPat' function
type Pattern      = Expr

----- Value domain-----
data Value =
    Unit
  | IntVal Integer
  | BoolVal Bool
  | ChanHandle ChanID
  | Closure Arg Env Expr
  | Injection Name [Value]    
  | Tuple [Value]
  | Exception Value
  
  -- Below we have denotable but not expressible values
  | Resume (Kont Value)
  | Halted ChanID
  | Waiting ChanID

----- State and its labels (lens-ish) -----
data GlobState = GlobState { _cst   :: ChanState Value (Kont Value), 
                             _sched :: Int }

-- TH creates labels for us (`cst' and `sched')
mkLabel ''GlobState

----- Operations for the state monad -----  
getCh :: ChanID -> State GlobState (CType Value (Kont Value))
getCh l = do cs <- Data.Label.Monadic.gets cst
             return (contents cs l) 

modifyCh :: ChanID -> CType Value (Kont Value) -> State GlobState ()
modifyCh l ct = Data.Label.Monadic.modify cst (\gs -> update gs l ct)

putCh :: State GlobState ChanID
putCh = Data.Label.Monadic.modifyAndGet cst fresh
         
----- Some useful instances -----
instance Eq Value where
  IntVal a == IntVal b         = a == b
  BoolVal a == BoolVal b       = a == b
  Unit == Unit                 = True
  Exception e1 == Exception e2 = e1 == e2
  _ == _                       = error "Not comparable"

instance Show Value where
  show (IntVal n)          = show n
  show (BoolVal b)         = if b then "true" else "false"
  show (ChanHandle a)      = "<handle " ++ show a ++ ">"
  show (Closure _ _ _)     = "<fundef>"
  show (Exception v )      = "<unhandled exception -> " ++ show v ++ ">"
  show (Tuple vs)          = "(" ++ intercalate "," (map show vs) ++ ")"
  show Unit                = "unit"
  show (Injection name vs) = if vs == []
                             then name
                             else name ++ " " ++ intercalate " " (map show vs)

  show (Waiting _)         = error "*Waiting* should not be printed"
  show (Halted _)          = error "*Halted* should not be printed"
  show (Resume _)          = error "*Resume* should not be printed"

---------------------------- Start of evaluator ----------------------------

eval :: Expr -> Env -> Kont Value

----- Basics -----
eval (Number n) _ = return (IntVal n)

eval (Variable v) env = return (find env v)

eval (Apply f e) env = 
  do Closure id env' body <- eval f env
     v                    <- eval e env
     eval body (define env' id v)

eval (If cond et ef) env =
  do cond <- eval cond env  
     case cond of
       BoolVal True -> eval et env
       BoolVal False -> eval ef env
       _ -> error "Boolean required in conditional"

eval (Lambda x e1) env = return $ Closure x env e1

eval (Pipe e1 e2) env = 
  do eval e1 env -- we discard the first expression's result
     eval e2 env

eval (Let d e1) env =
  do env' <- elab d env 
     eval e1 env'

----- Pattern matching -----
eval (Injector name args) env = 
  do vs <- values evs 
     return $ Injection name vs
  where evs = map (`eval` env) args

eval (Match ex cases) env = 
  do v <- eval ex env 
     case matchpat v cases env of
       Just (pex, env') -> eval pex env'
       Nothing          -> return $ Injection "ExcMatch" []

----- Concurrency -----
eval (Send ce ve) env =
  do v <- eval (SendP ce ve) env
     case v of 
       Exception _ -> shift pX $ \_ -> return v
       _           -> return v

eval (SendP ce ve) env = 
  shift pP$ \rest -> 
  do 
    ChanHandle l <- eval ce env 
    v <- eval ve env 
    sus <- lift $ -- descend to the state monad, to see if we suspend or not
      getCh l >>= \ chanState -> 
        -- based on the state, we decide what the next state is
        case chanState of 
          Empty -> 
            do modifyCh l (WR v rest)
               return $ Halted l
          Ready res _ -> 
            do modifyCh l $ Ready res (WR v rest)
               return $ Halted l
          WW rk -> 
            do modifyCh l $ Ready (rk v) Empty
               return $ Resume (rest Unit)
          Closed -> 
            return (Resume $ rest (Exception $ Injection "ExcClosed" []))
    case sus of 
      Resume res -> res              -- resume execution, no scheduler involved
      Halted _   -> return sus       -- return to scheduler

-- The code for Receive is almost identical to the one for Send
eval (Receive ce) env =
  do v <- eval (ReceiveP ce) env
     case v of 
       Exception _ -> (shift pX $ \_ -> return v)
       _           -> return v

eval (ReceiveP ce) env = 
  shift pP$ \rest ->
  do 
    ChanHandle l <- eval ce env
    sus <- lift $ 
      getCh l >>= \ chanState -> 
        case chanState of 
          Empty -> 
            do modifyCh l (WW rest)
               return $ Halted l
          Ready res _ -> 
            do modifyCh l $ Ready res (WW rest)
               return $ Halted l
          WR v sk -> 
            do modifyCh l (Ready (sk Unit) Empty) 
               return (Resume $ rest v)
          Closed -> 
            return (Resume $ rest (Exception $ Injection "ExcClosed" []))
    case sus of 
      Resume res -> res 
      Halted _ -> return sus 

eval (Parallel cs) env = scheduler (components, []) 0
  where components = map (`createComponent` env) cs
        createComponent c env = pushPrompt pP (eval c env)

eval NewChan env = 
  lift $  
  do l <- putCh 
     modifyCh l Empty
     return $ ChanHandle l

eval (Close c) env = 
  do
    ChanHandle l <- eval c env
    lift $ 
      getCh l >>= \ chanState -> case chanState of 
        Empty        -> modifyCh l Closed
        Closed       -> error "already closed"
        Ready res _  -> modifyCh l (Ready res Closed)
        WR _ wk      -> modifyCh l (Ready (wk (Exception (Injection "ExcClosed" [])))
                                     Closed)
        WW rk        -> modifyCh l (Ready (rk (Exception (Injection "ExcClosed" [])))
                                     Closed)
    return Unit

----- Exception handling -----
eval (TryCatch ex pats) env =   
  do 
    -- First we delimit the context in which we evaluate the expression. If 
    -- we end in an error, we essentially discard this computation, since we 
    -- discard everything up to the closest `px' prompt.
    val <- pushPrompt pX (eval ex env)
    -- Check whether we have ended with an exception or not.
    case val of
      Exception e -> case matchpat e pats env of
                      Just (pex, env') -> eval pex env'
                      -- If no handler handles our error, propagate
                      Nothing          -> shift pX $ \_ -> return $ Exception e
      _           -> return val -- No error, so just return the value.
    
eval (Throw th) env = 
  shift pX $ \_ ->
  do v <- eval th env 
     case v of
       Injection n vs -> return $ Exception v
       _              -> error "Must throw a sum type"

----- Primitive operations -----
eval (BinPrim bop e1 e2) env = case bop of
  Plus -> arithmeticBOP (+) e1 e2 env
  Minus -> arithmeticBOP (-) e1 e2 env
  Times -> arithmeticBOP (*) e1 e2 env
  Div -> arithmeticBOP (div) e1 e2 env
  Mod -> arithmeticBOP (mod) e1 e2 env
  And -> logicBOP (&&) e1 e2 env
  Or -> logicBOP (||) e1 e2 env
  Equal -> do v1 <- eval e1 env 
              v2 <- eval e2 env 
              return $ BoolVal (v1 == v2)

eval (MonPrim mop e) env = 
  case mop of
    Neg -> 
      do IntVal n <- eval e env 
         return $ IntVal (-n)

-- Helper functions that abstract the pattern of evaluation for 
-- binary primitive operations
arithmeticBOP :: (Integer -> Integer -> Integer) -> 
                 Expr -> Expr -> Env -> Kont Value
arithmeticBOP op e1 e2 env = 
  do IntVal n1 <- eval e1 env 
     IntVal n2 <- eval e2 env  
     return $ IntVal (op n1 n2)

logicBOP :: (Bool -> Bool -> Bool) -> 
            Expr -> Expr -> Env -> Kont Value
logicBOP funcop e1 e2 env = 
  do BoolVal b1 <- eval e1 env 
     BoolVal b2 <- eval e2 env 
     return $ BoolVal (funcop b1 b2)

----- Environment expansion -----
elab :: Defn -> Env -> Kont Env
elab (Val x e) env =
  do v <- eval e env 
     return (define env x v)
elab (Rec x e) env =
  case e of
    Lambda fp body -> return env' 
      where env' = define env x (Closure fp env' body)
    _ -> error "RHS of letrec must be a lambda"
elab (Data _ ctors) env = foldM (\ env' cdef -> elab cdef env') env ctors

----- Scheduler -----
scheduler :: ([Kont Value], [Kont Value]) -> Int -> Kont Value
scheduler ([], rs) w = if w == 0 
                       then 
                         do vs <- values rs
                            return $ Tuple (reverse vs)
                       else scheduler (reverse rs, []) w
scheduler ((k:ks), rs) w = k >>= (\v -> case v of 
    Halted l     -> scheduler (ks, (return $ Waiting l):rs) (w + 1)
    Waiting l    -> lift (getCh l >>= (\chs -> case chs of 
                      Ready sk next -> modifyCh l next >>= (\() -> return $ Left sk)
                      _             -> return $ Right (return $ Waiting l)
                    )) >>= (\val -> case val of 
                      Left r -> scheduler ((r:ks), rs) (w - 1)
                      Right r -> scheduler (ks, (r:rs)) w
                    )
    v            -> scheduler (ks, (return v:rs)) w
  )

----- Helpers -----
values :: [Kont Value] -> Kont [Value]
values [] = return []
values (c:cvs) = 
  do v <- c 
     vs <- values cvs 
     return (v:vs)

-- TODO: Fix no error when undefined exception because of lazyness

-- Expr for the following two functions is a pattern (leaves are variables)
-- Note: while Pattern in the signatures below is a type synonym for Expr, 
-- we require that it is restricted to `Variable' and `Apply ...', where the
-- `Apply' would yield an injection. This could have been handled in a 
-- cleaner manner, but for ease of understanding we have imposed this 
-- "soft" restriction.  
matchpat :: Value -> [Pattern] -> Env -> Maybe (Expr, Env)
matchpat v [] env = Nothing
matchpat v ((Case pat ex):ps) env = 
  case (trymatch v pat env) of
    Just env' -> Just (ex, env')
    Nothing   -> matchpat v ps env

-- The following two mutually recursive functions try
-- to recursively match patterns, so we can match arbitrary 
-- deep patterns
trymatch :: Value -> Pattern -> Env -> Maybe Env
trymatch v (Variable i) env = Just $ define env i v
trymatch (Injection n vs) pat env =
    if n == n' 
    then accumBindings vs ps env
    else Nothing
  where 
    -- We transform the application to an injection for ease
    Injector n' ps = appToInj pat [] 
trymatch a b _ = error $ show a ++ show b

accumBindings :: [Value] -> [Pattern] -> Env -> Maybe Env
accumBindings [] [] env = Just env
accumBindings (v:vs) (p:ps) env = case trymatch v p env of
  Just env' -> accumBindings vs ps env'
  Nothing   -> Nothing 

-- Helper function that 
appToInj :: Expr -> [Expr] -> Expr
appToInj (Apply (Variable v) x) ps = Injector v (x:ps)
appToInj (Apply x y) ps = appToInj x (y:ps)

---------------------------- End of evaluator ----------------------------

-- Initial environment, which only exposes primitive data
-- We deal with primitive operations during parsing, by converting them into
-- non-application expressions, similar to OCaml
init_env :: Env
init_env =
  make_env [
    -- some primitive data 
    ("true", BoolVal True), 
    ("false", BoolVal False),
    ("unit", Unit),
    -- some primitive exceptions
    ("ExcClosed", Injection "ExcClosed" []),
    ("ExcInvalid", Injection "ExcInvalid" []),
    ("ExcMatch", Injection "ExcMatch" [])]

init_gs :: GlobState
init_gs = GlobState {_cst = empty_cst, _sched = 0}

-- Deal with top-state exprs and defs. Observe the nice compositionality: 
-- first run the (continuation) computation to produce a state computation,
-- which when ran produces the new state, together with the desired result.
obey :: Phrase -> ProgState -> (String, ProgState)
obey (Calculate exp) (env, mem) =
  let (v, mem') = (runState . runCC) (pushPrompt pX (eval exp env)) mem in 
  (show v, (env, mem'))
obey (Define def) (env, mem) =
  let x = def_lhs def in
  let (env', mem') = (runState . runCC) (elab def env) mem in 
  ("Added definition: " ++ x, (env', mem'))
