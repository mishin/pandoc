{-# LANGUAGE FlexibleContexts #-}
{-
Copyright (C) 2014-2016 Albert Krewinkel <tarleb+pandoc@moltkeplatz.de>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module      : Text.Pandoc.Readers.Org.Options
   Copyright   : Copyright (C) 2014-2016 Albert Krewinkel
   License     : GNU GPL, version 2 or above

   Maintainer  : Albert Krewinkel <tarleb+pandoc@moltkeplatz.de>

Parsers for Org-mode block elements.
-}
module Text.Pandoc.Readers.Org.Blocks
  ( blockList
  , meta
  ) where

import           Text.Pandoc.Readers.Org.BlockStarts
import           Text.Pandoc.Readers.Org.Inlines
import           Text.Pandoc.Readers.Org.ParserState
import           Text.Pandoc.Readers.Org.Parsing

import qualified Text.Pandoc.Builder as B
import           Text.Pandoc.Builder ( Inlines, Blocks )
import           Text.Pandoc.Definition
import           Text.Pandoc.Compat.Monoid ((<>))
import           Text.Pandoc.Options
import           Text.Pandoc.Shared ( compactify', compactify'DL )

import           Control.Arrow ( first )
import           Control.Monad ( foldM, guard, mzero )
import           Data.Char ( toLower, toUpper)
import           Data.List ( foldl', intersperse, isPrefixOf )
import qualified Data.Map as M
import           Data.Maybe ( fromMaybe, isNothing )
import           Network.HTTP ( urlEncode )


--
-- parsing blocks
--

-- | Get a list of blocks.
blockList :: OrgParser [Block]
blockList = do
  blocks' <- blocks
  st      <- getState
  return . B.toList $ runF blocks' st

-- | Get the meta information safed in the state.
meta :: OrgParser Meta
meta = do
  st <- getState
  return $ runF (orgStateMeta' st) st

blocks :: OrgParser (F Blocks)
blocks = mconcat <$> manyTill block eof

block :: OrgParser (F Blocks)
block = choice [ mempty <$ blanklines
               , table
               , orgBlock
               , figure
               , example
               , genericDrawer
               , specialLine
               , header
               , horizontalRule
               , list
               , latexFragment
               , noteBlock
               , paraOrPlain
               ] <?> "block"


--
-- Block Attributes
--

-- | Attributes that may be added to figures (like a name or caption).
data BlockAttributes = BlockAttributes
  { blockAttrName      :: Maybe String
  , blockAttrCaption   :: Maybe (F Inlines)
  , blockAttrKeyValues :: [(String, String)]
  }

stringyMetaAttribute :: (String -> Bool) -> OrgParser (String, String)
stringyMetaAttribute attrCheck = try $ do
  metaLineStart
  attrName <- map toUpper <$> many1Till nonspaceChar (char ':')
  guard $ attrCheck attrName
  skipSpaces
  attrValue <- anyLine
  return (attrName, attrValue)

blockAttributes :: OrgParser BlockAttributes
blockAttributes = try $ do
  kv <- many (stringyMetaAttribute attrCheck)
  let caption = foldl' (appendValues "CAPTION") Nothing kv
  let kvAttrs = foldl' (appendValues "ATTR_HTML") Nothing kv
  let name    = lookup "NAME" kv
  caption' <- maybe (return Nothing)
                    (fmap Just . parseFromString parseInlines)
                    caption
  kvAttrs' <- parseFromString keyValues . (++ "\n") $ fromMaybe mempty kvAttrs
  return $ BlockAttributes
           { blockAttrName = name
           , blockAttrCaption = caption'
           , blockAttrKeyValues = kvAttrs'
           }
 where
   attrCheck :: String -> Bool
   attrCheck attr =
     case attr of
       "NAME"      -> True
       "CAPTION"   -> True
       "ATTR_HTML" -> True
       _           -> False

   appendValues :: String -> Maybe String -> (String, String) -> Maybe String
   appendValues attrName accValue (key, value) =
     if key /= attrName
     then accValue
     else case accValue of
            Just acc -> Just $ acc ++ ' ':value
            Nothing  -> Just value

keyValues :: OrgParser [(String, String)]
keyValues = try $
  manyTill ((,) <$> key <*> value) newline
 where
   key :: OrgParser String
   key = try $ skipSpaces *> char ':' *> many1 nonspaceChar

   value :: OrgParser String
   value = skipSpaces *> manyTill anyChar endOfValue

   endOfValue :: OrgParser ()
   endOfValue =
     lookAhead $ (() <$ try (many1 spaceChar <* key))
              <|> () <$ newline


--
-- Org Blocks (#+BEGIN_... / #+END_...)
--

type BlockProperties = (Int, String)  -- (Indentation, Block-Type)

updateIndent :: BlockProperties -> Int -> BlockProperties
updateIndent (_, blkType) indent = (indent, blkType)

orgBlock :: OrgParser (F Blocks)
orgBlock = try $ do
  blockAttrs <- blockAttributes
  blockProp@(_, blkType) <- blockHeaderStart
  ($ blockProp) $
    case blkType of
      "comment" -> withRaw'   (const mempty)
      "html"    -> withRaw'   (return . (B.rawBlock blkType))
      "latex"   -> withRaw'   (return . (B.rawBlock blkType))
      "ascii"   -> withRaw'   (return . (B.rawBlock blkType))
      "example" -> withRaw'   (return . exampleCode)
      "quote"   -> withParsed (fmap B.blockQuote)
      "verse"   -> verseBlock
      "src"     -> codeBlock blockAttrs
      _         -> withParsed (fmap $ divWithClass blkType)

blockHeaderStart :: OrgParser (Int, String)
blockHeaderStart = try $ (,) <$> indentation <*> blockType
 where
  blockType = map toLower <$> (stringAnyCase "#+begin_" *> orgArgWord)

indentation :: OrgParser Int
indentation = try $ do
  tabStop  <- getOption readerTabStop
  s        <- many spaceChar
  return $ spaceLength tabStop s

spaceLength :: Int -> String -> Int
spaceLength tabStop s = (sum . map charLen) s
 where
  charLen ' '  = 1
  charLen '\t' = tabStop
  charLen _    = 0

withRaw'   :: (String   -> F Blocks) -> BlockProperties -> OrgParser (F Blocks)
withRaw'   f blockProp = (ignHeaders *> (f <$> rawBlockContent blockProp))

withParsed :: (F Blocks -> F Blocks) -> BlockProperties -> OrgParser (F Blocks)
withParsed f blockProp = (ignHeaders *> (f <$> parsedBlockContent blockProp))

ignHeaders :: OrgParser ()
ignHeaders = (() <$ newline) <|> (() <$ anyLine)

divWithClass :: String -> Blocks -> Blocks
divWithClass cls = B.divWith ("", [cls], [])

verseBlock :: BlockProperties -> OrgParser (F Blocks)
verseBlock blkProp = try $ do
  ignHeaders
  content <- rawBlockContent blkProp
  fmap B.para . mconcat . intersperse (pure B.linebreak)
    <$> mapM (parseFromString parseInlines) (map (++ "\n") . lines $ content)

exportsCode :: [(String, String)] -> Bool
exportsCode attrs = not (("rundoc-exports", "none") `elem` attrs
                         || ("rundoc-exports", "results") `elem` attrs)

exportsResults :: [(String, String)] -> Bool
exportsResults attrs = ("rundoc-exports", "results") `elem` attrs
                       || ("rundoc-exports", "both") `elem` attrs

followingResultsBlock :: OrgParser (Maybe (F Blocks))
followingResultsBlock =
       optionMaybe (try $ blanklines *> stringAnyCase "#+RESULTS:"
                                     *> blankline
                                     *> block)

codeBlock :: BlockAttributes -> BlockProperties -> OrgParser (F Blocks)
codeBlock blockAttrs blkProp = do
  skipSpaces
  (classes, kv)     <- codeHeaderArgs <|> (mempty <$ ignHeaders)
  leadingIndent     <- lookAhead indentation
  content           <- rawBlockContent (updateIndent blkProp leadingIndent)
  resultsContent    <- followingResultsBlock
  let id'            = fromMaybe mempty $ blockAttrName blockAttrs
  let includeCode    = exportsCode kv
  let includeResults = exportsResults kv
  let codeBlck       = B.codeBlockWith ( id', classes, kv ) content
  let labelledBlck   = maybe (pure codeBlck)
                             (labelDiv codeBlck)
                             (blockAttrCaption blockAttrs)
  let resultBlck     = fromMaybe mempty resultsContent
  return $ (if includeCode then labelledBlck else mempty)
           <> (if includeResults then resultBlck else mempty)
 where
   labelDiv blk value =
       B.divWith nullAttr <$> (mappend <$> labelledBlock value
                                       <*> pure blk)
   labelledBlock = fmap (B.plain . B.spanWith ("", ["label"], []))

rawBlockContent :: BlockProperties -> OrgParser String
rawBlockContent (indent, blockType) = try $
  unlines . map commaEscaped <$> manyTill indentedLine blockEnder
 where
   indentedLine = try $ ("" <$ blankline) <|> (indentWith indent *> anyLine)
   blockEnder = try $ skipSpaces *> stringAnyCase ("#+end_" <> blockType)

parsedBlockContent :: BlockProperties -> OrgParser (F Blocks)
parsedBlockContent blkProps = try $ do
  raw <- rawBlockContent blkProps
  parseFromString blocks (raw ++ "\n")

-- indent by specified number of spaces (or equiv. tabs)
indentWith :: Int -> OrgParser String
indentWith num = do
  tabStop <- getOption readerTabStop
  if num < tabStop
     then count num (char ' ')
     else choice [ try (count num (char ' '))
                 , try (char '\t' >> count (num - tabStop) (char ' ')) ]

type SwitchOption = (Char, Maybe String)

-- | Parse code block arguments
-- TODO: We currently don't handle switches.
codeHeaderArgs :: OrgParser ([String], [(String, String)])
codeHeaderArgs = try $ do
  language   <- skipSpaces *> orgArgWord
  _          <- skipSpaces *> (try $ switch `sepBy` (many1 spaceChar))
  parameters <- manyTill blockOption newline
  let pandocLang = translateLang language
  return $
    if hasRundocParameters parameters
    then ( [ pandocLang, rundocBlockClass ]
         , map toRundocAttrib (("language", language) : parameters)
         )
    else ([ pandocLang ], parameters)
 where
   hasRundocParameters = not . null
   toRundocAttrib = first ("rundoc-" ++)


switch :: OrgParser SwitchOption
switch = try $ simpleSwitch <|> lineNumbersSwitch
 where
   simpleSwitch = (\c -> (c, Nothing)) <$> (oneOf "-+" *> letter)
   lineNumbersSwitch = (\ls -> ('l', Just ls)) <$>
                       (string "-l \"" *> many1Till nonspaceChar (char '"'))

translateLang :: String -> String
translateLang "C"          = "c"
translateLang "C++"        = "cpp"
translateLang "emacs-lisp" = "commonlisp" -- emacs lisp is not supported
translateLang "js"         = "javascript"
translateLang "lisp"       = "commonlisp"
translateLang "R"          = "r"
translateLang "sh"         = "bash"
translateLang "sqlite"     = "sql"
translateLang cs = cs

-- | Prefix used for Rundoc classes and arguments.
rundocPrefix :: String
rundocPrefix = "rundoc-"

-- | The class-name used to mark rundoc blocks.
rundocBlockClass :: String
rundocBlockClass = rundocPrefix ++ "block"

blockOption :: OrgParser (String, String)
blockOption = try $ do
  argKey <- orgArgKey
  paramValue <- option "yes" orgParamValue
  return (argKey, paramValue)

orgParamValue :: OrgParser String
orgParamValue = try $
  skipSpaces
    *> notFollowedBy (char ':' )
    *> many1 (noneOf "\t\n\r ")
    <* skipSpaces

commaEscaped :: String -> String
commaEscaped (',':cs@('*':_))     = cs
commaEscaped (',':cs@('#':'+':_)) = cs
commaEscaped cs                   = cs

example :: OrgParser (F Blocks)
example = try $ do
  return . return . exampleCode =<< unlines <$> many1 exampleLine

exampleCode :: String -> Blocks
exampleCode = B.codeBlockWith ("", ["example"], [])

exampleLine :: OrgParser String
exampleLine = try $ exampleLineStart *> anyLine

horizontalRule :: OrgParser (F Blocks)
horizontalRule = return B.horizontalRule <$ try hline


--
-- Drawers
--

-- | A generic drawer which has no special meaning for org-mode.
-- Whether or not this drawer is included in the output depends on the drawers
-- export setting.
genericDrawer :: OrgParser (F Blocks)
genericDrawer = try $ do
  name    <- map toUpper <$> drawerStart
  content <- manyTill drawerLine (try drawerEnd)
  state   <- getState
  -- Include drawer if it is explicitly included in or not explicitly excluded
  -- from the list of drawers that should be exported.  PROPERTIES drawers are
  -- never exported.
  case (exportDrawers . orgStateExportSettings $ state) of
    _           | name == "PROPERTIES" -> return mempty
    Left  names | name `elem`    names -> return mempty
    Right names | name `notElem` names -> return mempty
    _                                  -> drawerDiv name <$> parseLines content
 where
  parseLines :: [String] -> OrgParser (F Blocks)
  parseLines = parseFromString blocks . (++ "\n") . unlines

  drawerDiv :: String -> F Blocks -> F Blocks
  drawerDiv drawerName = fmap $ B.divWith (mempty, [drawerName, "drawer"], mempty)

drawerLine :: OrgParser String
drawerLine = anyLine

drawerEnd :: OrgParser String
drawerEnd = try $
  skipSpaces *> stringAnyCase ":END:" <* skipSpaces <* newline

-- | Read a :PROPERTIES: drawer and return the key/value pairs contained
-- within.
propertiesDrawer :: OrgParser [(String, String)]
propertiesDrawer = try $ do
  drawerType <- drawerStart
  guard $ map toUpper drawerType == "PROPERTIES"
  manyTill property (try drawerEnd)
 where
   property :: OrgParser (String, String)
   property = try $ (,) <$> key <*> value

   key :: OrgParser String
   key = try $ skipSpaces *> char ':' *> many1Till nonspaceChar (char ':')

   value :: OrgParser String
   value = try $ skipSpaces *> manyTill anyChar (try $ skipSpaces *> newline)

keyValuesToAttr :: [(String, String)] -> Attr
keyValuesToAttr kvs =
  let
    lowerKvs = map (\(k, v) -> (map toLower k, v)) kvs
    id'  = fromMaybe mempty . lookup "custom_id" $ lowerKvs
    cls  = fromMaybe mempty . lookup "class"     $ lowerKvs
    kvs' = filter (flip notElem ["custom_id", "class"] . fst) lowerKvs
  in
    (id', words cls, kvs')


--
-- Figures
--

-- | Figures (Image on a line by itself, preceded by name and/or caption)
figure :: OrgParser (F Blocks)
figure = try $ do
  figAttrs <- blockAttributes
  src <- skipSpaces *> selfTarget <* skipSpaces <* newline
  guard . not . isNothing . blockAttrCaption $ figAttrs
  guard (isImageFilename src)
  let figName    = fromMaybe mempty $ blockAttrName figAttrs
  let figCaption = fromMaybe mempty $ blockAttrCaption figAttrs
  let figKeyVals = blockAttrKeyValues figAttrs
  let attr       = (mempty, mempty, figKeyVals)
  return $ (B.para . B.imageWith attr src (withFigPrefix figName) <$> figCaption)
 where
   withFigPrefix :: String -> String
   withFigPrefix cs =
     if "fig:" `isPrefixOf` cs
     then cs
     else "fig:" ++ cs

   selfTarget :: OrgParser String
   selfTarget = try $ char '[' *> linkTarget <* char ']'


--
-- Comments, Options and Metadata
--

addLinkFormat :: String
              -> (String -> String)
              -> OrgParser ()
addLinkFormat key formatter = updateState $ \s ->
  let fs = orgStateLinkFormatters s
  in s{ orgStateLinkFormatters = M.insert key formatter fs }

specialLine :: OrgParser (F Blocks)
specialLine = fmap return . try $ metaLine <|> commentLine

-- The order, in which blocks are tried, makes sure that we're not looking at
-- the beginning of a block, so we don't need to check for it
metaLine :: OrgParser Blocks
metaLine = mempty <$ metaLineStart <* (optionLine <|> declarationLine)

commentLine :: OrgParser Blocks
commentLine = commentLineStart *> anyLine *> pure mempty

declarationLine :: OrgParser ()
declarationLine = try $ do
  key <- metaKey
  inlinesF <- metaInlines
  updateState $ \st ->
    let meta' = B.setMeta <$> pure key <*> inlinesF <*> pure nullMeta
    in st { orgStateMeta' = orgStateMeta' st <> meta' }
  return ()

metaInlines :: OrgParser (F MetaValue)
metaInlines = fmap (MetaInlines . B.toList) <$> inlinesTillNewline

metaKey :: OrgParser String
metaKey = map toLower <$> many1 (noneOf ": \n\r")
                      <*  char ':'
                      <*  skipSpaces

optionLine :: OrgParser ()
optionLine = try $ do
  key <- metaKey
  case key of
    "link"    -> parseLinkFormat >>= uncurry addLinkFormat
    "options" -> () <$ sepBy spaces exportSetting
    _         -> mzero

--
-- Export Settings
--

-- | Read and process org-mode specific export options.
exportSetting :: OrgParser ()
exportSetting = choice
  [ booleanSetting "^" setExportSubSuperscripts
  , ignoredSetting "'"
  , ignoredSetting "*"
  , ignoredSetting "-"
  , ignoredSetting ":"
  , ignoredSetting "<"
  , ignoredSetting "\\n"
  , ignoredSetting "arch"
  , ignoredSetting "author"
  , ignoredSetting "c"
  , ignoredSetting "creator"
  , complementableListSetting "d" setExportDrawers
  , ignoredSetting "date"
  , ignoredSetting "e"
  , ignoredSetting "email"
  , ignoredSetting "f"
  , ignoredSetting "H"
  , ignoredSetting "inline"
  , ignoredSetting "num"
  , ignoredSetting "p"
  , ignoredSetting "pri"
  , ignoredSetting "prop"
  , ignoredSetting "stat"
  , ignoredSetting "tags"
  , ignoredSetting "tasks"
  , ignoredSetting "tex"
  , ignoredSetting "timestamp"
  , ignoredSetting "title"
  , ignoredSetting "toc"
  , ignoredSetting "todo"
  , ignoredSetting "|"
  ] <?> "export setting"

booleanSetting :: String -> ExportSettingSetter Bool -> OrgParser ()
booleanSetting settingIdentifier setter = try $ do
  string settingIdentifier
  char ':'
  value <- elispBoolean
  updateState $ modifyExportSettings setter value

-- | Read an elisp boolean.  Only NIL is treated as false, non-NIL values are
-- interpreted as true.
elispBoolean :: OrgParser Bool
elispBoolean = try $ do
  value <- many1 nonspaceChar
  return $ case map toLower value of
             "nil" -> False
             "{}"  -> False
             "()"  -> False
             _     -> True

-- | A list or a complement list (i.e. a list starting with `not`).
complementableListSetting :: String
                          -> ExportSettingSetter (Either [String] [String])
                          -> OrgParser ()
complementableListSetting settingIdentifier setter = try $ do
  _     <- string settingIdentifier <* char ':'
  value <- choice [ Left <$> complementStringList
                  , Right <$> stringList
                  , (\b -> if b then Left [] else Right []) <$> elispBoolean
                  ]
  updateState $ modifyExportSettings setter value
 where
   -- Read a plain list of strings.
   stringList :: OrgParser [String]
   stringList = try $
     char '('
       *> sepBy elispString spaces
       <* char ')'

   -- Read an emacs lisp list specifying a complement set.
   complementStringList :: OrgParser [String]
   complementStringList = try $
     string "(not "
       *> sepBy elispString spaces
       <* char ')'

   elispString :: OrgParser String
   elispString = try $
     char '"'
       *> manyTill alphaNum (char '"')

ignoredSetting :: String -> OrgParser ()
ignoredSetting s = try (() <$ string s <* char ':' <* many1 nonspaceChar)


parseLinkFormat :: OrgParser ((String, String -> String))
parseLinkFormat = try $ do
  linkType <- (:) <$> letter <*> many (alphaNum <|> oneOf "-_") <* skipSpaces
  linkSubst <- parseFormat
  return (linkType, linkSubst)

-- | An ad-hoc, single-argument-only implementation of a printf-style format
-- parser.
parseFormat :: OrgParser (String -> String)
parseFormat = try $ do
  replacePlain <|> replaceUrl <|> justAppend
 where
   -- inefficient, but who cares
   replacePlain = try $ (\x -> concat . flip intersperse x)
                     <$> sequence [tillSpecifier 's', rest]
   replaceUrl   = try $ (\x -> concat . flip intersperse x . urlEncode)
                     <$> sequence [tillSpecifier 'h', rest]
   justAppend   = try $ (++) <$> rest

   rest            = manyTill anyChar         (eof <|> () <$ oneOf "\n\r")
   tillSpecifier c = manyTill (noneOf "\n\r") (try $ string ('%':c:""))

--
-- Headers
--

-- | Headers
header :: OrgParser (F Blocks)
header = try $ do
  level    <- headerStart
  title    <- manyTill inline (lookAhead $ optional headerTags <* newline)
  tags     <- option [] headerTags
  newline
  propAttr <- option nullAttr (keyValuesToAttr <$> propertiesDrawer)
  inlines  <- runF (tagTitle title tags) <$> getState
  attr     <- registerHeader propAttr inlines
  return $ pure (B.headerWith attr level inlines)
 where
   tagTitle :: [F Inlines] -> [String] -> F Inlines
   tagTitle title tags = trimInlinesF . mconcat $ title <> map tagToInlineF tags

   tagToInlineF :: String -> F Inlines
   tagToInlineF t = return $ B.spanWith ("", ["tag"], [("data-tag-name", t)]) mempty

   headerTags :: OrgParser [String]
   headerTags = try $
     let tag = many1 (alphaNum <|> oneOf "@%#_") <* char ':'
     in skipSpaces
          *> char ':'
          *> many1 tag
          <* skipSpaces


--
-- Tables
--

data OrgTableRow = OrgContentRow (F [Blocks])
                 | OrgAlignRow [Alignment]
                 | OrgHlineRow

-- OrgTable is strongly related to the pandoc table ADT.  Using the same
-- (i.e. pandoc-global) ADT would mean that the reader would break if the
-- global structure was to be changed, which would be bad.  The final table
-- should be generated using a builder function.  Column widths aren't
-- implemented yet, so they are not tracked here.
data OrgTable = OrgTable
  { orgTableAlignments :: [Alignment]
  , orgTableHeader     :: [Blocks]
  , orgTableRows       :: [[Blocks]]
  }

table :: OrgParser (F Blocks)
table = try $ do
  blockAttrs <- blockAttributes
  lookAhead tableStart
  do
    rows <- tableRows
    let caption = fromMaybe (return mempty) $ blockAttrCaption blockAttrs
    return $ (<$> caption) . orgToPandocTable . normalizeTable =<< rowsToTable rows

orgToPandocTable :: OrgTable
                 -> Inlines
                 -> Blocks
orgToPandocTable (OrgTable aligns heads lns) caption =
  B.table caption (zip aligns $ repeat 0) heads lns

tableRows :: OrgParser [OrgTableRow]
tableRows = try $ many (tableAlignRow <|> tableHline <|> tableContentRow)

tableContentRow :: OrgParser OrgTableRow
tableContentRow = try $
  OrgContentRow . sequence <$> (tableStart *> many1Till tableContentCell newline)

tableContentCell :: OrgParser (F Blocks)
tableContentCell = try $
  fmap B.plain . trimInlinesF . mconcat <$> manyTill inline endOfCell

tableAlignRow :: OrgParser OrgTableRow
tableAlignRow = try $ do
  tableStart
  cells <- many1Till tableAlignCell newline
  -- Empty rows are regular (i.e. content) rows, not alignment rows.
  guard $ any (/= AlignDefault) cells
  return $ OrgAlignRow cells

tableAlignCell :: OrgParser Alignment
tableAlignCell =
  choice [ try $ emptyCell *> return AlignDefault
         , try $ skipSpaces
                   *> char '<'
                   *> tableAlignFromChar
                   <* many digit
                   <* char '>'
                   <* emptyCell
         ] <?> "alignment info"
    where emptyCell = try $ skipSpaces *> endOfCell

tableAlignFromChar :: OrgParser Alignment
tableAlignFromChar = try $
  choice [ char 'l' *> return AlignLeft
         , char 'c' *> return AlignCenter
         , char 'r' *> return AlignRight
         ]

tableHline :: OrgParser OrgTableRow
tableHline = try $
  OrgHlineRow <$ (tableStart *> char '-' *> anyLine)

endOfCell :: OrgParser Char
endOfCell = try $ char '|' <|> lookAhead newline

rowsToTable :: [OrgTableRow]
            -> F OrgTable
rowsToTable = foldM rowToContent emptyTable
 where emptyTable = OrgTable mempty mempty mempty

normalizeTable :: OrgTable -> OrgTable
normalizeTable (OrgTable aligns heads rows) = OrgTable aligns' heads rows
 where
   refRow = if heads /= mempty
            then heads
            else if rows == mempty then mempty else head rows
   cols = length refRow
   fillColumns base padding = take cols $ base ++ repeat padding
   aligns' = fillColumns aligns AlignDefault

-- One or more horizontal rules after the first content line mark the previous
-- line as a header.  All other horizontal lines are discarded.
rowToContent :: OrgTable
             -> OrgTableRow
             -> F OrgTable
rowToContent orgTable row =
  case row of
    OrgHlineRow       -> return singleRowPromotedToHeader
    OrgAlignRow as    -> return . setAligns $ as
    OrgContentRow cs  -> appendToBody cs
 where
   singleRowPromotedToHeader :: OrgTable
   singleRowPromotedToHeader = case orgTable of
     OrgTable{ orgTableHeader = [], orgTableRows = b:[] } ->
            orgTable{ orgTableHeader = b , orgTableRows = [] }
     _   -> orgTable

   setAligns :: [Alignment] -> OrgTable
   setAligns aligns = orgTable{ orgTableAlignments = aligns }

   appendToBody :: F [Blocks] -> F OrgTable
   appendToBody frow = do
     newRow <- frow
     let oldRows = orgTableRows orgTable
     -- NOTE: This is an inefficient O(n) operation.  This should be changed
     -- if performance ever becomes a problem.
     return orgTable{ orgTableRows = oldRows ++ [newRow] }


--
-- LaTeX fragments
--
latexFragment :: OrgParser (F Blocks)
latexFragment = try $ do
  envName <- latexEnvStart
  content <- mconcat <$> manyTill anyLineNewline (latexEnd envName)
  return . return $ B.rawBlock "latex" (content `inLatexEnv` envName)
 where
   c `inLatexEnv` e = mconcat [ "\\begin{", e, "}\n"
                              , c
                              , "\\end{", e, "}\n"
                              ]

latexEnd :: String -> OrgParser ()
latexEnd envName = try $
  () <$ skipSpaces
     <* string ("\\end{" ++ envName ++ "}")
     <* blankline


--
-- Footnote defintions
--
noteBlock :: OrgParser (F Blocks)
noteBlock = try $ do
  ref <- noteMarker <* skipSpaces
  content <- mconcat <$> blocksTillHeaderOrNote
  addToNotesTable (ref, content)
  return mempty
 where
   blocksTillHeaderOrNote =
     many1Till block (eof <|> () <$ lookAhead noteMarker
                          <|> () <$ lookAhead headerStart)

-- Paragraphs or Plain text
paraOrPlain :: OrgParser (F Blocks)
paraOrPlain = try $ do
  ils <- parseInlines
  nl <- option False (newline *> return True)
  -- Read block as paragraph, except if we are in a list context and the block
  -- is directly followed by a list item, in which case the block is read as
  -- plain text.
  try (guard nl
       *> notFollowedBy (inList *> (() <$ orderedListStart <|> bulletListStart))
       *> return (B.para <$> ils))
    <|>  (return (B.plain <$> ils))

inlinesTillNewline :: OrgParser (F Inlines)
inlinesTillNewline = trimInlinesF . mconcat <$> manyTill inline newline


--
-- list blocks
--

list :: OrgParser (F Blocks)
list = choice [ definitionList, bulletList, orderedList ] <?> "list"

definitionList :: OrgParser (F Blocks)
definitionList = try $ do n <- lookAhead (bulletListStart' Nothing)
                          fmap B.definitionList . fmap compactify'DL . sequence
                            <$> many1 (definitionListItem $ bulletListStart' (Just n))

bulletList :: OrgParser (F Blocks)
bulletList = try $ do n <- lookAhead (bulletListStart' Nothing)
                      fmap B.bulletList . fmap compactify' . sequence
                        <$> many1 (listItem (bulletListStart' $ Just n))

orderedList :: OrgParser (F Blocks)
orderedList = fmap B.orderedList . fmap compactify' . sequence
              <$> many1 (listItem orderedListStart)

bulletListStart' :: Maybe Int -> OrgParser Int
-- returns length of bulletList prefix, inclusive of marker
bulletListStart' Nothing  = do ind <- length <$> many spaceChar
                               oneOf (bullets $ ind == 0)
                               skipSpaces1
                               return (ind + 1)
bulletListStart' (Just n) = do count (n-1) spaceChar
                               oneOf (bullets $ n == 1)
                               many1 spaceChar
                               return n

-- Unindented lists are legal, but they can't use '*' bullets.
-- We return n to maintain compatibility with the generic listItem.
bullets :: Bool -> String
bullets unindented = if unindented then "+-" else "*+-"

definitionListItem :: OrgParser Int
                   -> OrgParser (F (Inlines, [Blocks]))
definitionListItem parseMarkerGetLength = try $ do
  markerLength <- parseMarkerGetLength
  term <- manyTill (noneOf "\n\r") (try definitionMarker)
  line1 <- anyLineNewline
  blank <- option "" ("\n" <$ blankline)
  cont <- concat <$> many (listContinuation markerLength)
  term' <- parseFromString parseInlines term
  contents' <- parseFromString blocks $ line1 ++ blank ++ cont
  return $ (,) <$> term' <*> fmap (:[]) contents'
 where
   definitionMarker =
     spaceChar *> string "::" <* (spaceChar <|> lookAhead newline)


-- parse raw text for one list item, excluding start marker and continuations
listItem :: OrgParser Int
         -> OrgParser (F Blocks)
listItem start = try . withContext ListItemState $ do
  markerLength <- try start
  firstLine <- anyLineNewline
  blank <- option "" ("\n" <$ blankline)
  rest <- concat <$> many (listContinuation markerLength)
  parseFromString blocks $ firstLine ++ blank ++ rest

-- continuation of a list item - indented and separated by blankline or endline.
-- Note: nested lists are parsed as continuations.
listContinuation :: Int
                 -> OrgParser String
listContinuation markerLength = try $
  notFollowedBy' blankline
  *> (mappend <$> (concat <$> many1 listLine)
              <*> many blankline)
 where listLine = try $ indentWith markerLength *> anyLineNewline

-- | Parse any line, include the final newline in the output.
anyLineNewline :: OrgParser String
anyLineNewline = (++ "\n") <$> anyLine
