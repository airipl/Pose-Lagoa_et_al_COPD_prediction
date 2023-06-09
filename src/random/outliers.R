#!/bin/Rscript
###############################################################################
######################## OUTLIERS DETECTION ##################################
###############################################################################
## Run the function to detect the outliers 10000 times
## (as it generates sligthly different results each time)

## -----------------------------------------------------------------------------
# Set working directory
setwd("../../data/raw/GSE47460/")

library(dplyr);library(arrayQualityMetrics); library(Biobase)

## -----------------------------------------------------------------------------
# Read arguments from commnad line
if (length(args)==0) {
  stop("At least one argument must be supplied (input file).n", call.=FALSE)
} else if (length(args)==1) {
  # default output file
  a = as.numeric(commandArgs(trailingOnly=TRUE))
}

plt <- 6480
load(paste("../../ExpressionSetObjects/",plt,"/eset_outliers.Rda", sep=""))

# Run the function 50 times
outliers <- c()

for(i in seq(a, a+49)){
  preparedData = prepdata(expressionset = eset_outliers,
                          intgroup = c(),
                          do.logtransform = FALSE)
  bo = aqm.boxplot(preparedData)
  out_samples_bo <- rownames(as.data.frame(bo@outliers@which))
  outliers <- c(outliers, out_samples_bo)
}

## -----------------------------------------------------------------------------
# Save the list of outlier samples
write(outliers, paste("../../Visualization/outliers/outliers_",plt,"_",a,".txt", sep=""), append = TRUE)
