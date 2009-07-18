{- |
   Module      : Data.GraphViz.Types
   Description : Definition of the GraphViz types.
   Copyright   : (c) Matthew Sackman, Ivan Lazar Miljenovic
   License     : 3-Clause BSD-style
   Maintainer  : Ivan.Miljenovic@gmail.com

   This module defines the overall types and methods that interact
   with them for the GraphViz library.  The specifications are based
   loosely upon the information available at:
     <http://graphviz.org/doc/info/lang.html>
-}

module Data.GraphViz.Types
    ( DotGraph(..)
    , GraphID(..)
    , DotNode(..)
    , DotEdge(..)
    , parseDotGraph
    , setID
    , makeStrict
    , isValidGraph
    , invalidAttributes
    ) where

import Data.GraphViz.Attributes
import Data.GraphViz.ParserCombinators

import Data.Maybe
import Control.Monad

-- -----------------------------------------------------------------------------

-- | The internal representation of a graph in Dot form.
data DotGraph = DotGraph { strictGraph     :: Bool
                         , directedGraph   :: Bool
                         , graphID         :: Maybe GraphID
                         , graphAttributes :: [Attribute]
                         , graphNodes      :: [DotNode]
                         , graphEdges      :: [DotEdge]
                         }
                deriving (Eq, Read)

-- | A strict graph disallows multiple edges.
makeStrict   :: DotGraph -> DotGraph
makeStrict g = g { strictGraph = True }

setID     :: GraphID -> DotGraph -> DotGraph
setID i g = g { graphID = Just i }

-- | Check if all the @Attribute@s are being used correctly.
isValidGraph   :: DotGraph -> Bool
isValidGraph g = null gas && null nas && null eas
    where
      (gas, nas, eas) = invalidAttributes g

-- | Return all those @Attribute@s which aren't being used properly.
invalidAttributes   :: DotGraph -> ( [Attribute]
                                   , [(DotNode, Attribute)]
                                   , [(DotEdge, Attribute)]
                                   )
invalidAttributes g = ( invalidGraphAttributes g
                      , concatMap invalidNodeAttributes $ graphNodes g
                      , concatMap invalidEdgeAttributes $ graphEdges g
                      )

invalidGraphAttributes :: DotGraph -> [Attribute]
invalidGraphAttributes = filter (not . usedByGraphs) . graphAttributes

instance Show DotGraph where
    show g
        = unlines $ (hdr ++ " {") : (rest ++ ["}"])
        where
          hdr = strct . addId $ gType
          strct = if strictGraph g
                  then ("strict " ++)
                  else id
          addId = maybe id (\ i -> flip (++) $ ' ' : show i) $ graphID g
          gType = if directedGraph g then dirGraph else undirGraph
          rest = case graphAttributes g of
                   [] -> nodesEdges
                   a -> ("\tgraph " ++ show a ++ ";") : nodesEdges
          nodesEdges = map show (graphNodes g) ++ map show (graphEdges g)

dirGraph :: String
dirGraph = "digraph"

undirGraph :: String
undirGraph = "graph"

-- | Parse a limited subset of the Dot language to form a 'DotGraph'
--   (that is, the caveats listed in "Data.GraphViz.Attributes" aside,
--   Dot graphs are parsed if they match the layout of DotGraph).
parseDotGraph :: Parse DotGraph
parseDotGraph = parse

instance Parseable DotGraph where
    parse = do isStrict <- parseAndSpace $ hasString "strict"
               gType <- strings [dirGraph,undirGraph]
               gId <- optional (parse `discard` whitespace)
               whitespace
               char '{'
               skipToNewline
               as <- liftM concat $
                     many (whitespace' >>
                           oneOf [ string "edge" >> skipToNewline >> return []
                                 , string "node" >> skipToNewline >> return []
                                 , string "graph" >> whitespace
                                              >> parse `discard` skipToNewline
                                 ]
                          )
               ns <- many1 (whitespace' >> parse `discard` skipToNewline)
               es <- many1 (whitespace' >> parse `discard` skipToNewline)
               char '}'
               return DotGraph { strictGraph = isStrict
                               , directedGraph = gType == dirGraph
                               , graphID = gId
                               , graphAttributes = as
                               , graphNodes = ns
                               , graphEdges = es
                               }

            `adjustErr`
            (++ "\nNot a valid DotGraph")

-- -----------------------------------------------------------------------------

data GraphID = Str String
             | Num Double
             | QStr QuotedString
             | HTML URL
               deriving (Eq, Read)

instance Show GraphID where
    show (Str str)  = str
    show (Num n)    = show n
    show (QStr str) = show str
    show (HTML url) = show url

instance Parseable GraphID where
    parse = oneOf [ liftM Str stringBlock
                  , liftM Num parse
                  , liftM QStr parse
                  , liftM HTML parse
                  ]
            `adjustErr`
            (++ "\nNot a valid GraphID")

-- -----------------------------------------------------------------------------

-- | A node in 'DotGraph' is either a singular node, or a cluster
--   containing nodes (or more clusters) within it.
--   At the moment, clusters are not parsed.
data DotNode
    = DotNode { nodeID :: Int
              , nodeAttributes :: [Attribute]
              }
    | DotCluster { clusterID         :: String
                 , clusterAttributes :: [Attribute]
                 , clusterElems      :: [DotNode]
                 }
      deriving (Eq, Read)

invalidNodeAttributes                :: DotNode -> [(DotNode, Attribute)]
invalidNodeAttributes n@DotNode{}    = map ((,) n)
                                       . filter (not . usedByNodes)
                                       $ nodeAttributes n
invalidNodeAttributes c@DotCluster{} = cErr ++ nErr
    where
      cErr = map ((,) c) . filter (not . usedByClusters)
             $ clusterAttributes c
      nErr = concatMap invalidNodeAttributes $ clusterElems c

instance Show DotNode where
    show = init . unlines . addTabs . nodesToString

nodesToString :: DotNode -> [String]
nodesToString n@(DotNode {})
    | null nAs  = [nID ++ ";"]
    | otherwise = [nID ++ (' ':(show nAs ++ ";"))]
    where
      nID = show $ nodeID n
      nAs = nodeAttributes n
nodesToString c@(DotCluster {})
    = ["subgraph cluster_" ++ clusterID c ++ " {"] ++ addTabs inner ++ ["}"]
    where
      inner = case clusterAttributes c of
                [] -> nodes
                a  -> ("graph " ++ show a ++ ";") : nodes
      nodes = concatMap nodesToString $ clusterElems c


instance Parseable DotNode where
    parse = do nId <- parse
               as <- optional (whitespace >> parse)
               char ';'
               return DotNode { nodeID = nId
                              , nodeAttributes = fromMaybe [] as }
            `adjustErr`
            (++ "\nNot a valid DotNode")

-- | Prefix each 'String' with a tab character.
addTabs :: [String] -> [String]
addTabs = map ('\t':)

-- -----------------------------------------------------------------------------

-- | An edge in 'DotGraph'.
data DotEdge = DotEdge { edgeHeadNodeID :: Int
                       , edgeTailNodeID :: Int
                       , edgeAttributes :: [Attribute]
                       , directedEdge   :: Bool
                       }
             deriving (Eq, Read)

invalidEdgeAttributes   :: DotEdge -> [(DotEdge, Attribute)]
invalidEdgeAttributes e = map ((,) e)
                          . filter (not . usedByEdges)
                          $ edgeAttributes e

instance Show DotEdge where
    show e
        = '\t' : (show (edgeHeadNodeID e)
                  ++ edge ++ show (edgeTailNodeID e) ++ attributes)
          where
            edge = " " ++ (if directedEdge e then dirEdge else undirEdge) ++ " "
            attributes = case edgeAttributes e of
                           [] -> ";"
                           a  -> ' ':(show a ++ ";")

dirEdge :: String
dirEdge = "->"

undirEdge :: String
undirEdge = "--"

instance Parseable DotEdge where
    parse = do whitespace'
               eHead <- parse
               whitespace
               edgeType <- strings [dirEdge,undirEdge]
               whitespace
               eTail <- parse
               as <- optional (whitespace >> parse)
               char ';'
               return DotEdge { edgeHeadNodeID = eHead
                              , edgeTailNodeID = eTail
                              , edgeAttributes = fromMaybe [] as
                              , directedEdge   = edgeType == dirEdge
                              }
            `adjustErr`
            (++ "\nNot a valid DotEdge")

-- -----------------------------------------------------------------------------
