{-# LANGUAGE PatternGuards, KindSignatures #-}
{-# LANGUAGE ExistentialQuantification, Rank2Types, ImpredicativeTypes #-}

-- Implementation courtesy of Oleg Kiselyov. 
-- https://mail.haskell.org/pipermail/haskell/2010-September/022282.html
-- Below is Oleg's description of the library.

-- Monad transformer for multi-prompt delimited control
-- It implements the superset of the interface described in
--
--   A Monadic Framework for Delimited Continuations
--   R. Kent Dybvig, Simon Peyton Jones, and Amr Sabry
--   JFP, v17, N6, pp. 687--730, 2007.
--   http://www.cs.indiana.edu/cgi-bin/techreports/TRNNN.cgi?trnum=TR615
--
-- The first main difference is the use of generalized prompts, which
-- do not have to be created with new_prompt and therefore can be defined
-- at top level. That removes one of the main practical drawbacks of
-- Dybvig et al implementations: the necessity to carry around the prompts
-- throughout all the code.
--
-- The delimited continuation monad is parameterized by the flavor
-- of generalized prompts. The end of this code defines several flavors;
-- the library users may define their own. User-defined flavors are 
-- especially useful when user's code uses a small closed set of answer-types. 
-- Flavors PP and PD below are more general, assuming the set of possible
-- answer-types is open and Typeable. If the user wishes to create several
-- distinct prompts with the same answer-types, the user should use
-- the flavor of prompts accepting an integral prompt identifier, such as PD.
-- Prompts of the flavor PD correspond to the prompts in Dybvig, Peyton Jones,
-- Sabry framework. If the user wishes to generate unique prompts, the user
-- should arrange himself for the generation of unique integers
-- (using a state monad, for example). On the other hand, the user
-- can differentiate answer-types using `newtype.' The latter can
-- only produce the set of distinct prompts that is fixed at run-time.
-- Sometimes that is sufficient. There is not need to create a gensym
-- monad then.

-- The second feature of our implementation is the use of the 
-- bubble-up semantics:
-- See page 57 of http://okmij.org/ftp/gengo/CAG-talk.pdf
-- This present code implements, for the first time, the delimited 
-- continuation monad CC *without* the use of the continuation monad. 
-- This code implements CC in direct-style, so to speak.
-- Instead of continuations, we rely on exceptions. Our code has a lot
-- in common with the Error monad. In fact, our code implements
-- an Error monad for resumable exceptions.

module CCExc (
	      CC,			-- Types
	      SubCont,
	      CCT,
	      Prompt,

	      -- Basic delimited control operations
	      pushPrompt,
              takeSubCont,
              pushSubCont,
              runCC,

              -- Useful derived operations
              captureUpTo,
            P2, pP, pX, -- The prompts we use in our interpreter.
	      ) where

import Control.Monad.Trans
import Data.Typeable			-- for prompts of the flavor PP, PD

-- Delimited-continuation monad transformer
-- It is parameterized by the prompt flavor p
newtype CC p m a = CC {unCC:: m (CCV p m a)}

-- The captured sub-continuation
type SubCont p m a b = CC p m a -> CC p m b

-- Produced result: a value or a resumable exception
data CCV p m a = Iru a
	       | forall x. Deru (SubCont p m x a) (p m x) -- The bubble

-- The type of control operator's body
type CCT p m a w = SubCont p m a w -> CC p m w

-- Generalized prompts for the answer-type w: an injection-projection pair
type Prompt p m w = 
    (forall x. CCT p m x w -> p m x,
     forall x. p m x -> Maybe (CCT p m x w))


-- --------------------------------------------------------------------
-- CC monad: general monadic operations

instance Monad m => Monad (CC p m) where
    return = CC . return . Iru

    m >>= f = CC $ unCC m >>= check
	where check (Iru a)         = unCC $ f a
	      check (Deru ctx body) = return $ Deru (\x -> ctx x >>= f) body

instance Monad m => Applicative (CC p m) where
    pure = return

instance Monad m => Functor (CC p m) where
    fmap f m = CC $ unCC m >>= \v -> case v of
        Iru a -> return (Iru $ f a)
        (Deru ctx body) -> return $ Deru (\x -> fmap f (ctx x)) body

instance Monad m => MonadFail (CC p m) where
	fail = error "pattern failed for CC"

instance MonadTrans (CC p) where
    lift m = CC (m >>= return . Iru)

instance MonadIO m => MonadIO (CC p m) where
    liftIO = lift . liftIO

-- --------------------------------------------------------------------
-- Basic Operations of the delimited control interface

pushPrompt :: Monad m =>
	      Prompt p m w -> CC p m w -> CC p m w
pushPrompt p@(_,proj) body = CC $ unCC body >>= check
 where
 check e@Iru{} = return e
 check (Deru ctx body) | Just b <- proj body  = unCC $ b ctx
 check (Deru ctx body) = return $ Deru (\x -> pushPrompt p (ctx x)) body


-- Create the initial bubble
takeSubCont :: Monad m =>
	       Prompt p m w -> CCT p m x w -> CC p m x
takeSubCont p@(inj,_) body = CC . return $ Deru id (inj body)

-- Apply the captured continuation
pushSubCont :: Monad m => SubCont p m a b -> CC p m a -> CC p m b
pushSubCont = ($)

runCC :: Monad m => CC (p :: (* -> *) -> * -> *) m a -> m a
runCC m = unCC m >>= check
 where
 check (Iru x) = return x
 check _       = error "Escaping bubble: you have forgotten pushPrompt"


-- --------------------------------------------------------------------
-- Useful derived operations

captureUpTo :: Monad m => 
	  Prompt p m w -> ((a -> CC p m w) -> CC p m w) -> CC p m a
captureUpTo p f = takeSubCont p $ \sk -> 
	       pushPrompt p (f (\c -> 
		  pushPrompt p (pushSubCont sk (return c))))

-- --------------------------------------------------------------------
-- Prompt flavors

-- Prompts for the closed set of answer-types
-- The following prompt flavor P2, for two answer-types w1 and w2,
-- is given as an example. Typically, a programmer would define their
-- own variant data type with variants for the answer-types that occur
-- in their program.

newtype P2 w1 w2 m x = 
  P2 (Either (CCT (P2 w1 w2) m x w1) (CCT (P2 w1 w2) m x w2))

-- There are two generalized prompts of the flavor P2:
pP :: Prompt (P2 w1 w2) m w1
pP = (inj, prj)
 where
 inj = P2 . Left
 prj (P2 (Left x)) = Just x
 prj _ = Nothing

pX :: Prompt (P2 w1 w2) m w2
pX = (inj, prj)
 where
 inj = P2 . Right
 prj (P2 (Right x)) = Just x
 prj _ = Nothing
