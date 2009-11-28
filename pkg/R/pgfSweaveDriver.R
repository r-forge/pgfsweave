######################################################################
## Copyright (C) 2008, Cameron Bracken <cameron.bracken@gmail.com>
##                     Charlie Sharpsteen <source@shaprpsteen.net>
##
## This program is free software; you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation; either version 2 of the License, or
## (at your option) any later version.
##
## This program is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## GNU General Public License for more details.
##
## You should have received a copy of the GNU General Public License
## along with this program; if not, write to the Free Software
## Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
## 02110-1301, USA
#####################################################################

######################################################################
## Heavily relies on functions of cacheSweave but reimplements the 
## Sweave driver function.

pgfSweaveDriver <- function() {
        list(
             setup = pgfSweaveSetup,
             runcode = pgfSweaveRuncode,
             writedoc = utils::RweaveLatexWritedoc,
             finish = utils::RweaveLatexFinish,
             checkopts = utils::RweaveLatexOptions
             )
}

        
source('R/cacheSweaveUnexportedFunctions.R')


################################################################################
## [RDP]
## The major modification is here: Rather than evaluate expressions
## and leave them in the global environment, we evaluate them in a
## local environment (that has globalenv() as the parent) and then
## store the assignments in a 'stashR' database.  If an expression
## does not give rise to new R objects, then nothing is saved.
##
## For each expression ('expr'), we compute a digest and associate
## with that digest the names of the objects that were created by
## evaluating the expression.  That way, for a given cached
## expression, we know which keys to lazy-load from the cache when
## evaluation is skipped.
## end [RDP]
##
## [CWB]
## minor modification to the original function 'cacheSweaveEvalWithOpt' has 
## two outputs helping to improve the recognition of changes to code chunks
## end [CWB]
################################################################################


pgfSweaveEvalWithOpt <- function (expr, options) {
        chunkDigest <- options$chunkDigest
        
        ## 'expr' is a single expression, so something like 'a <- 1'
        res <- NULL
        chunkChanged <- TRUE

        if(!options$eval)
                return(res)
        if(options$cache) {
                cachedir <- getCacheDir()

                ## Create database name from chunk label and MD5
                ## digest
                dbName <- makeChunkDatabaseName(cachedir, options,
                                                        chunkDigest)
                exprDigest <- mangleDigest(digest(expr))

                ## Create 'stashR' database
                db <- new("localDB", dir = dbName, name = basename(dbName))

                ## If the current expression is not cached, then
                ## evaluate the expression and dump the resulting
                ## objects to the database.  Otherwise, just read the
                ## vector of keys from the database

                if(!dbExists(db, exprDigest)){
                    keys <- try({
                                evalAndDumpToDB(db, expr, exprDigest)
                                }, silent = TRUE)
                }
                else{
                    keys <- dbFetch(db, exprDigest)
                    chunkChanged <- FALSE
                }
                

                ## If there was an error then just return the
                ## condition object and let Sweave deal with it.
                if(inherits(keys, "try-error"))
                        return(list(err=keys,chunkChanged=chunkChanged))

                dbLazyLoad(db, globalenv(), keys)
        }
        else {
                ## If caching is turned off, just evaluate the expression
                ## in the global environment
                res <- try(.Internal(eval.with.vis(expr, .GlobalEnv,
                                                   baseenv())),
                           silent=TRUE)
                if(inherits(res, "try-error"))
                        return(list(err=res,chunkChanged=chunkChanged))
                if(options$print | (options$term & res$visible))
                        print(res$value)
        }
        list(err=res,chunkChanged=chunkChanged)
}

## Add the 'pgf' and 'external' and 'pdflatex' option to the list
pgfSweaveSetup <- function(file, syntax,
                            output=NULL, quiet=FALSE, debug=FALSE, echo=TRUE,
                            eval=TRUE, split=FALSE, stylepath=TRUE, 
                            pdf=FALSE, eps=FALSE, cache=FALSE, pgf=FALSE, 
                            tikz=TRUE, external=FALSE, tex.driver="pdflatex")
{

        out <- utils::RweaveLatexSetup(file, syntax, output=NULL, quiet=FALSE,
                                       debug=FALSE, echo=TRUE, eval=TRUE,
                                       split=FALSE, stylepath=TRUE, pdf=TRUE,
                                       eps=TRUE)

        ######################################################################
        ## Additions here [RDP]
        ## Add the (non-standard) options for code chunks with caching
        out$options[["cache"]] <- cache

        ## The pgfSweave options [CWB]
        out$options[["pgf"]] <- pgf
        out$options[["tikz"]] <- tikz
        out$options[["external"]] <- external
        out[["tex.driver"]] <- tex.driver
        ## end [CWB]

        ## We assume that each .Rnw file gets its own map file
        out[["mapFile"]] <- makeMapFileName(file)
        file.create(out[["mapFile"]])  ## Overwrite an existing file
        ## End additions [RDP]
        
        ## [CWB]  create a shell script with a command for each modified
        ##        graphic 
        out[["shellFile"]] <- makeExternalShellScriptName(file)
        out[["srcfileName"]] <- sub("\\.Rnw$", "\\.tex", file)
        file.create(out[["shellFile"]])  ## Overwrite an existing file
        ######################################################################

        out
}

makeExternalShellScriptName <- function(Rnwfile) {
        shellfile <- sub("\\.Rnw$", "\\.sh", Rnwfile)

        ## Don''t clobber
        if(identical(shellfile, Rnwfile))
                shellfile <- paste(Rnwfile, "sh", sep = ".")
        shellfile
}



## This function is essentially unchanged from the original Sweave
## version, except I compute the digest of the entire chunk, write out
## information to the map file, and use 'cacheSweaveEvalWithOpt'
## instead.  Note that everything in this function operates at the
## chunk level.  The code has been copied from R 2.5.0.

pgfSweaveRuncode <- function(object, chunk, options) {
        
        if(!(options$engine %in% c("R", "S"))){
                return(object)
        }

        if(!object$quiet){
                cat(formatC(options$chunknr, width=2), ":")
                if(options$echo) cat(" echo")
                if(options$keep.source) cat(" keep.source")
                if(options$eval){
                        if(options$print) cat(" print")
                        if(options$term) cat(" term")
                        cat("", options$results)
                        if(options$fig){
                                if(options$eps) cat(" eps")
                                if(options$pdf) cat(" pdf")
                                if(options$pgf) cat(" pgf")
                                if(options$tikz | options$external) cat(" tikz")
                                if(options$external) cat(" external")
                        }
                }
                if(!is.null(options$label))
                        cat(" (label=", options$label, ")", sep="")
                cat("\n")
        }

        chunkprefix <- RweaveChunkPrefix(options)

        if(options$split){
                ## [x][[1]] avoids partial matching of x
                chunkout <- object$chunkout[chunkprefix][[1]]
                if(is.null(chunkout)){
                        chunkout <- file(paste(chunkprefix, "tex", sep="."), 
                                                                        "w")
                        if(!is.null(options$label))
                                object$chunkout[[chunkprefix]] <- chunkout
                }
        }
        else    chunkout <- object$output

        saveopts <- options(keep.source=options$keep.source)
        on.exit(options(saveopts))

        SweaveHooks(options, run=TRUE)
    
        ## parse entire chunk block
        chunkexps <- try(parse(text=chunk), silent=TRUE)
        RweaveTryStop(chunkexps, options)

        ## [CWB] Create a DB entry which is simply the digest of the text of 
        ## the chunk so that if anything has changed the chunk will be 
        ## recognised as having a change if ANYTHING gets changed, even white 
        ## space. this still doesnt fix the problem of actually caching the 
        ## plotting commands and others which do not create objects in the 
        ## global environment when they are evaluated but at least the figures 
        ## will get regenerated.
        chunkTextEvalString <- paste("chunkText <- '", 
                                        digest(paste(chunk,collapse='')), 
                                        "'", sep='')
        #print(chunkTextEvalString)
        if(substr(chunk[1],1,9)!='chunkText')
                chunk <- c(chunkTextEvalString, chunk)
        ## end [CWB]
 
        ## Adding my own stuff here [RDP]
        ## Add 'chunkDigest' to 'options'
        options <- writeChunkMetadata(object, chunk, options)
        ## End adding my own stuff [RDP]

        openSinput <- FALSE
        openSchunk <- FALSE

        if(length(chunkexps)==0)
                return(object)

        srclines <- attr(chunk, "srclines")
        linesout <- integer(0)
        srcline <- srclines[1]

        srcrefs <- attr(chunkexps, "srcref")
        if (options$expand)
                lastshown <- 0
        else
                lastshown <- srcline - 1
        thisline <- 0
        for(nce in 1:length(chunkexps)){
                ce <- chunkexps[[nce]]
                if (nce <= length(srcrefs) && 
                    !is.null(srcref <- srcrefs[[nce]])) {
                        if (options$expand) {
                                srcfile <- attr(srcref, "srcfile")
                                showfrom <- srcref[1]
                                showto <- srcref[3]
                        } else {
                                srcfile <- object$srcfile
                                showfrom <- srclines[srcref[1]]
                                showto <- srclines[srcref[3]]
                        }
                        dce <- getSrcLines(srcfile, lastshown+1, showto)
                        leading <- showfrom-lastshown
                        lastshown <- showto
                        srcline <- srclines[srcref[3]]
                        while (length(dce) 
                                && length(grep("^[ \\t]*$", dce[1]))) {
                                dce <- dce[-1]
                                leading <- leading - 1
                        }
                } else {
                        dce <- deparse(ce, 
                                    width.cutoff = 0.75*getOption("width"))
                        leading <- 1
                }
                if(object$debug)
                        cat("\nRnw> ", paste(dce, collapse="\n+  "),"\n")
                if(options$echo && length(dce)){
                        if(!openSinput){
                                if(!openSchunk){
                                        cat("\\begin{Schunk}\n",
                                            file=chunkout, append=TRUE)
                                        linesout[thisline + 1] <- srcline
                                        thisline <- thisline + 1
                                        openSchunk <- TRUE
                                }
                                cat("\\begin{Sinput}",
                                    file=chunkout, append=TRUE)
                                openSinput <- TRUE
                        }
                        cat("\n", paste(getOption("prompt"), dce[1:leading], 
                                        sep="", collapse="\n"),
                            file=chunkout, append=TRUE, sep="")
                        if (length(dce) > leading)
                                cat("\n", paste(getOption("continue"), 
                                                dce[-(1:leading)], sep="",
                                                collapse="\n"),
                                    file=chunkout, append=TRUE, sep="")
                        linesout[thisline + 1:length(dce)] <- srcline
                        thisline <- thisline + length(dce)
                }

                ## tmpcon <- textConnection("output", "w")
                ## avoid the limitations (and overhead) of output text
                ## connections
                tmpcon <- file()
                sink(file=tmpcon)
                err <- NULL
                
                ## [RDP] change this line to use my EvalWithOpt function
                if(options$eval) err <- pgfSweaveEvalWithOpt(ce, options)
                ## [CWB] added another output specifying if the code chunk
                ##       was changed or not. This was an ititial attempt to 
                ##       improve cacheSweave''s  recognition of chages in a
                ##       code chunk though it is defunct now.
                chunkChanged <- FALSE#err$chunkChanged
                err <- err$err
                ## [CWB] end
                ## [RDP] end change

                cat("\n") # make sure final line is complete
                sink()
                output <- readLines(tmpcon)
                close(tmpcon)
                ## delete empty output
                if(length(output)==1 & output[1]=="") output <- NULL

                RweaveTryStop(err, options)

                if(object$debug)
                        cat(paste(output, collapse="\n"))

                if(length(output)>0 & (options$results != "hide")){

                        if(openSinput){
                                cat("\n\\end{Sinput}\n", file=chunkout,
                                                            append=TRUE)
                                linesout[thisline + 1:2] <- srcline
                                thisline <- thisline + 2
                                openSinput <- FALSE
                        }
                        if(options$results=="verbatim"){
                                if(!openSchunk){
                                        cat("\\begin{Schunk}\n",
                                            file=chunkout, append=TRUE)
                                        linesout[thisline + 1] <- srcline
                                        thisline <- thisline + 1
                                        openSchunk <- TRUE
                                }
                                cat("\\begin{Soutput}\n",
                                    file=chunkout, append=TRUE)
                                linesout[thisline + 1] <- srcline
                                thisline <- thisline + 1
                        }

                        output <- paste(output,collapse="\n")
                        if(options$strip.white %in% c("all", "true")){
                                output <- sub("^[[:space:]]*\n", "", output)
                                output <- sub("\n[[:space:]]*$", "", output)
                                if(options$strip.white=="all")
                                        output <- sub("\n[[:space:]]*\n", 
                                                            "\n", output)
                        }
                        cat(output, file=chunkout, append=TRUE)
                        count <- sum(strsplit(output, NULL)[[1]] == "\n")
                        if (count > 0) {
                                linesout[thisline + 1:count] <- srcline
                                thisline <- thisline + count
                        }

                        remove(output)

                        if(options$results=="verbatim"){
                                cat("\n\\end{Soutput}\n", file=chunkout, 
                                                            append=TRUE)
                                linesout[thisline + 1:2] <- srcline
                                thisline <- thisline + 2
                        }
                }
        }

        if(openSinput){
                cat("\n\\end{Sinput}\n", file=chunkout, append=TRUE)
                linesout[thisline + 1:2] <- srcline
                thisline <- thisline + 2
        }

        if(openSchunk){
                cat("\\end{Schunk}\n", file=chunkout, append=TRUE)
                linesout[thisline + 1] <- srcline
                thisline <- thisline + 1
        }

        if(is.null(options$label) & options$split)
                close(chunkout)

        if(options$split & options$include){
                cat("\\input{", chunkprefix, "}\n", sep="",
                    file=object$output, append=TRUE)
                linesout[thisline + 1] <- srcline
                thisline <- thisline + 1
        }

        if(options$fig && options$eval){
                ## [CWB] adding checking for external options
                pdfExists <- file.exists(paste(chunkprefix, "pdf", sep="."))
                epsExists <- file.exists(paste(chunkprefix, "eps", sep="."))
                if(options$eps & !options$pgf & !options$tikz){
                    if(!options$external | (chunkChanged | !epsExists) ){
                        
                            # [CWB] the useKerning option was added in R 2.9.0
                            # so check for the R version and set the 
                            # useKerning option to false if 2.8.x or less is 
                            # used. Check will break for R version 1.9, but I
                            # suppose someone using that version will have
                            # bigger problems.
                        if(getRversion() < "2.9.0")
                            grDevices::postscript(file = paste(chunkprefix, 
                                                                "eps", 
                                                                sep="."),
                                                  width=options$width, 
                                                  height=options$height,
                                                  paper="special",  
                                                  horizontal=FALSE)
                        else 
                            grDevices::postscript(file = paste(chunkprefix, 
                                                                "eps", 
                                                                sep="."),
                                                  width=options$width, 
                                                  height=options$height,
                                                  paper="special",  
                                                  horizontal=FALSE,
                                                  useKerning=FALSE)

                        err <- try({SweaveHooks(options, run=TRUE)
                                    eval(chunkexps, envir=.GlobalEnv)})
                        grDevices::dev.off()
                        if(inherits(err, "try-error")) stop(err)
                    }
                }
                if(options$pdf & !options$pgf & !options$tikz){
                    if(!options$external | (chunkChanged | !pdfExists) ){
                        grDevices::pdf(file=paste(chunkprefix, 
                                                    "pdf", sep="."),
                                       width=options$width,
                                       height=options$height,
                                       version=options$pdf.version,
                                       encoding=options$pdf.encoding)

                        err <- try({SweaveHooks(options, run=TRUE)
                                    eval(chunkexps, envir=.GlobalEnv)})
                        grDevices::dev.off()
                        if(inherits(err, "try-error")) stop(err)
                    }
                }

                #############################################
                ## [CWB] Here are the new options related to graphics output 
                ## pgf: uses eps2pgf with the `-m directcopy` option to create 
                ##      a pgf file in which the text is interperted as a tex 
                ##      string 
                ## 
                ## external: uses the external feature in 
                ##   the TeX package pgf to include the compiled pdf file if
                ##   available
                ##

                if(options$pgf){
                    if(chunkChanged | !pdfExists){
                        
                            # [CWB] the useKerning option was added in R 2.9.0
                            # so check for the R version and set the 
                            # useKerning option to false if 2.8.x or less is 
                            # used. Check will break for R version 1.9, but I
                            # suppose someone using that version will have
                            # bigger problems. 
                        if(getRversion() < "2.9.0")
                            grDevices::postscript(file = paste(chunkprefix, 
                                                                "eps", 
                                                                sep="."),
                                                  width=options$width, 
                                                  height=options$height,
                                                  paper="special",  
                                                  horizontal=FALSE)
                        else 
                            grDevices::postscript(file = paste(chunkprefix, 
                                                                "eps", 
                                                                sep="."),
                                                  width=options$width, 
                                                  height=options$height,
                                                  paper="special",  
                                                  horizontal=FALSE,
                                                  useKerning=FALSE)

                        err <- try({SweaveHooks(options, run=TRUE)
                                    eval(chunkexps, envir=.GlobalEnv)})
                        grDevices::dev.off()
                        if(inherits(err, "try-error")) stop(err)

                        eps2pgf <- system.file(package='pgfSweave')
                        eps2pgf <- paste('java -jar ',eps2pgf,
                            '/java/eps2pgf/eps2pgf.jar -m directcopy',sep='')
                                                
                        cat('Generating pgf file from:',paste(chunkprefix,  
                                                        "eps",sep="."),'\n')
                        err <- try(system(paste(eps2pgf,paste(chunkprefix, 
                                                            "eps",sep="."))))
                                                
                        if(inherits(err, "try-error")) stop(err)
                    }
                }
                if(options$tikz){
                    if(chunkChanged | !pdfExists){
                        tikzDevice::tikz(file=paste(chunkprefix, "tikz", sep="."),
                                         width=options$width,
                                         height=options$height)

                        err <- try({SweaveHooks(options, run=TRUE)
                                      eval(chunkexps, envir=.GlobalEnv)})
                        grDevices::dev.off()
                        if(inherits(err, "try-error")) stop(err)
                    }
                }
                
                if(options$external){
                        if( chunkChanged | !pdfExists && 
                                (!options$pdf && !options$eps)){

                                shellFile <- object[["shellFile"]]
                                tex.driver <- object[["tex.driver"]]
                                
                                cat(tex.driver, ' --jobname=', chunkprefix,
                                    ' ',object[["srcfileName"]], '\n', sep='',  
                                    file=shellFile, append=TRUE)
                        }
                }
                if(options$include && options$external) {
                        cat("\\beginpgfgraphicnamed{",chunkprefix,"}\n",
                            sep="",file=object$output, append=TRUE)
                        linesout[thisline + 1] <- srcline
                        thisline <- thisline + 1
                } 
                if(options$include && !options$pgf && !options$tikz && !options$external) {
                        cat("\\includegraphics{", chunkprefix, "}\n", sep="",
                            file=object$output, append=TRUE)
                        linesout[thisline + 1] <- srcline
                        thisline <- thisline + 1
                }
                if(options$include && (options$pgf || options$tikz)) {
                        #if tikz is TRUE or both tikz and pgf are true, 
                        # use tikz, otherwise use pgf
                        suffix <- ifelse(options$tikz,'tikz','pgf')
                        cat("\\input{", paste(chunkprefix,suffix,sep='.'),
                            "}\n", sep="", file=object$output, append=TRUE)
                        linesout[thisline + 1] <- srcline
                        thisline <- thisline + 1
                }
                if(options$include && options$external) {
                        cat("\\endpgfgraphicnamed\n",
                            sep="",file=object$output, append=TRUE)
                        linesout[thisline + 1] <- srcline
                        thisline <- thisline + 1
                }
                ##end graphics options [CWB]
                #############################################
        }
        object$linesout <- c(object$linesout, linesout)
        return(object)
}