#
#
#           The Nim Compiler
#        (c) Copyright 2012 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## This module implements the passes functionality. A pass must implement the
## `TPass` interface.

import
  strutils, options, ast, astalgo, llstream, msgs, platform, os,
  condsyms, idents, renderer, types, extccomp, math, magicsys, nversion,
  nimsets, syntaxes, times, rodread, idgen, modulegraphs, reorder, rod,
  lineinfos


type
  TPassContext* = object of RootObj # the pass's context
    rd*: PRodReader  # != nil if created by "openCached"

  PPassContext* = ref TPassContext

  TPassOpen* = proc (graph: ModuleGraph; module: PSym; cache: IdentCache): PPassContext {.nimcall.}
  TPassOpenCached* =
    proc (graph: ModuleGraph; module: PSym, rd: PRodReader): PPassContext {.nimcall.}
  TPassClose* = proc (graph: ModuleGraph; p: PPassContext, n: PNode): PNode {.nimcall.}
  TPassProcess* = proc (p: PPassContext, topLevelStmt: PNode): PNode {.nimcall.}

  TPass* = tuple[open: TPassOpen, openCached: TPassOpenCached,
                 process: TPassProcess, close: TPassClose,
                 isFrontend: bool]

  TPassData* = tuple[input: PNode, closeOutput: PNode]
  TPasses* = openArray[TPass]

# a pass is a tuple of procedure vars ``TPass.close`` may produce additional
# nodes. These are passed to the other close procedures.
# This mechanism used to be used for the instantiation of generics.

proc makePass*(open: TPassOpen = nil,
               openCached: TPassOpenCached = nil,
               process: TPassProcess = nil,
               close: TPassClose = nil,
               isFrontend = false): TPass =
  result.open = open
  result.openCached = openCached
  result.close = close
  result.process = process
  result.isFrontend = isFrontend

# the semantic checker needs these:
var
  gImportModule*: proc (graph: ModuleGraph; m: PSym, fileIdx: FileIndex; cache: IdentCache): PSym {.nimcall.}
  gIncludeFile*: proc (graph: ModuleGraph; m: PSym, fileIdx: FileIndex; cache: IdentCache): PNode {.nimcall.}

# implementation

proc skipCodegen*(config: ConfigRef; n: PNode): bool {.inline.} =
  # can be used by codegen passes to determine whether they should do
  # something with `n`. Currently, this ignores `n` and uses the global
  # error count instead.
  result = config.errorCounter > 0

const
  maxPasses = 10

type
  TPassContextArray = array[0..maxPasses - 1, PPassContext]

var
  gPasses: array[0..maxPasses - 1, TPass]
  gPassesLen*: int

proc clearPasses*(g: ModuleGraph) =
  gPassesLen = 0

proc registerPass*(g: ModuleGraph; p: TPass) =
  gPasses[gPassesLen] = p
  inc(gPassesLen)

proc carryPass*(g: ModuleGraph; p: TPass, module: PSym; cache: IdentCache;
                m: TPassData): TPassData =
  var c = p.open(g, module, cache)
  result.input = p.process(c, m.input)
  result.closeOutput = if p.close != nil: p.close(g, c, m.closeOutput)
                       else: m.closeOutput

proc carryPasses*(g: ModuleGraph; nodes: PNode, module: PSym;
                  cache: IdentCache; passes: TPasses) =
  var passdata: TPassData
  passdata.input = nodes
  for pass in passes:
    passdata = carryPass(g, pass, module, cache, passdata)

proc openPasses(g: ModuleGraph; a: var TPassContextArray;
                module: PSym; cache: IdentCache) =
  for i in countup(0, gPassesLen - 1):
    if not isNil(gPasses[i].open):
      a[i] = gPasses[i].open(g, module, cache)
    else: a[i] = nil

proc openPassesCached(g: ModuleGraph; a: var TPassContextArray, module: PSym,
                      rd: PRodReader) =
  for i in countup(0, gPassesLen - 1):
    if not isNil(gPasses[i].openCached):
      a[i] = gPasses[i].openCached(g, module, rd)
      if a[i] != nil:
        a[i].rd = rd
    else:
      a[i] = nil

proc closePasses(graph: ModuleGraph; a: var TPassContextArray) =
  var m: PNode = nil
  for i in countup(0, gPassesLen - 1):
    if not isNil(gPasses[i].close): m = gPasses[i].close(graph, a[i], m)
    a[i] = nil                # free the memory here

proc processTopLevelStmt(n: PNode, a: var TPassContextArray): bool =
  # this implements the code transformation pipeline
  var m = n
  for i in countup(0, gPassesLen - 1):
    if not isNil(gPasses[i].process):
      m = gPasses[i].process(a[i], m)
      if isNil(m): return false
  result = true

proc processTopLevelStmtCached(n: PNode, a: var TPassContextArray) =
  # this implements the code transformation pipeline
  var m = n
  for i in countup(0, gPassesLen - 1):
    if not isNil(gPasses[i].openCached): m = gPasses[i].process(a[i], m)

proc closePassesCached(graph: ModuleGraph; a: var TPassContextArray) =
  var m: PNode = nil
  for i in countup(0, gPassesLen - 1):
    if not isNil(gPasses[i].openCached) and not isNil(gPasses[i].close):
      m = gPasses[i].close(graph, a[i], m)
    a[i] = nil                # free the memory here

proc resolveMod(conf: ConfigRef; module, relativeTo: string): FileIndex =
  let fullPath = findModule(conf, module, relativeTo)
  if fullPath.len == 0:
    result = InvalidFileIDX
  else:
    result = fileInfoIdx(conf, fullPath)

proc processImplicits(conf: ConfigRef; implicits: seq[string], nodeKind: TNodeKind,
                      a: var TPassContextArray; m: PSym) =
  # XXX fixme this should actually be relative to the config file!
  let gCmdLineInfo = newLineInfo(FileIndex(0), 1, 1)
  let relativeTo = toFullPath(conf, m.info)
  for module in items(implicits):
    # implicit imports should not lead to a module importing itself
    if m.position != resolveMod(conf, module, relativeTo).int32:
      var importStmt = newNodeI(nodeKind, gCmdLineInfo)
      var str = newStrNode(nkStrLit, module)
      str.info = gCmdLineInfo
      importStmt.addSon str
      if not processTopLevelStmt(importStmt, a): break

proc processModule*(graph: ModuleGraph; module: PSym, stream: PLLStream,
                    rd: PRodReader; cache: IdentCache): bool {.discardable.} =
  if graph.stopCompile(): return true
  var
    p: TParsers
    a: TPassContextArray
    s: PLLStream
    fileIdx = module.fileIdx
  if module.id < 0:
    # new module caching mechanism:
    for i in 0..<gPassesLen:
      if not isNil(gPasses[i].open) and not gPasses[i].isFrontend:
        a[i] = gPasses[i].open(graph, module, cache)
      else:
        a[i] = nil

    var stmtIndex = 0
    var doContinue = true
    while doContinue:
      let n = loadNode(graph, module, stmtIndex)
      if n == nil or graph.stopCompile(): break
      #if n.kind == nkImportStmt:
      #  echo "yes and it's ", n
      inc stmtIndex
      var m = n
      for i in 0..<gPassesLen:
        if not isNil(gPasses[i].process) and not gPasses[i].isFrontend:
          m = gPasses[i].process(a[i], m)
          if isNil(m):
            doContinue = false
            break

    var m: PNode = nil
    for i in 0..<gPassesLen:
      if not isNil(gPasses[i].close) and not gPasses[i].isFrontend:
        m = gPasses[i].close(graph, a[i], m)
      a[i] = nil
  elif rd == nil:
    openPasses(graph, a, module, cache)
    if stream == nil:
      let filename = toFullPathConsiderDirty(graph.config, fileIdx)
      s = llStreamOpen(filename, fmRead)
      if s == nil:
        rawMessage(graph.config, errCannotOpenFile, filename)
        return false
    else:
      s = stream
    while true:
      openParsers(p, fileIdx, s, cache, graph.config)

      if sfSystemModule notin module.flags:
        # XXX what about caching? no processing then? what if I change the
        # modules to include between compilation runs? we'd need to track that
        # in ROD files. I think we should enable this feature only
        # for the interactive mode.
        processImplicits graph.config, graph.config.implicitImports, nkImportStmt, a, module
        processImplicits graph.config, graph.config.implicitIncludes, nkIncludeStmt, a, module

      while true:
        if graph.stopCompile(): break
        var n = parseTopLevelStmt(p)
        if n.kind == nkEmpty: break
        if {sfNoForward, sfReorder} * module.flags != {}:
          # read everything, no streaming possible
          var sl = newNodeI(nkStmtList, n.info)
          sl.add n
          while true:
            var n = parseTopLevelStmt(p)
            if n.kind == nkEmpty: break
            sl.add n
          if sfReorder in module.flags:
            sl = reorder(graph, sl, module, cache)
          discard processTopLevelStmt(sl, a)
          break
        elif not processTopLevelStmt(n, a): break
      closeParsers(p)
      if s.kind != llsStdIn: break
    closePasses(graph, a)
    # id synchronization point for more consistent code generation:
    idSynchronizationPoint(1000)
  else:
    openPassesCached(graph, a, module, rd)
    var n = loadInitSection(rd)
    for i in countup(0, sonsLen(n) - 1):
      if graph.stopCompile(): break
      processTopLevelStmtCached(n.sons[i], a)
    closePassesCached(graph, a)
  result = true
