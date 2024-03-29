module Environment(Environment, empty_env, find, maybe_find,
                   define, make_env, names, within, defargs) where

import qualified Data.Map as Map

type Ident = String

newtype Environment v = Env (Map.Map Ident v) deriving Show

empty_env :: Environment v
empty_env = Env Map.empty

find :: Environment v -> Ident -> v
find (Env m) x =
  case Map.lookup x m of
    Just v -> v
    Nothing -> error (show x ++ " is not defined")

maybe_find :: Environment v -> Ident -> Maybe v
maybe_find (Env m) x = Map.lookup x m

define :: Environment v -> Ident -> v -> Environment v
define (Env m) x v = Env (Map.insert x v m)

make_env :: [(Ident, v)] -> Environment v
make_env defs = Env (Map.fromList defs)

names :: Environment v -> [Ident]
names (Env m) = Map.keys m

within :: Environment v -> Environment v -> Environment v
within (Env m1) (Env m2) = Env (Map.union m2 m1)

defargs :: Environment v -> [Ident] -> [v] -> Environment v
defargs env fps args =
  if length args == length fps then
    foldl (\ env' (x, v) -> define env' x v) env (zip fps args)
  else
    error "wrong number of args"