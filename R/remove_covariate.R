
#' Removing Covariate Effect form Expression Data
#' 
#' The main purpose of this function is to remove batch effect from the data.
#' Batch can be associated with different days of sample processing (as factor)
#' or with run order (continuous). Can also be used to remove any unwanted
#' effects from the data.
#' 
#' @param x MSnSet or ExpressionSet object
#' @param cov_name covariate name. Must be in pData(x). At this point it can be
#' only one name.
#' 
#' @note The algorithm essentially uses an LM. The reason for re-inventing the 
#' wheel is presense of missing values in proteomics datasets more then usual.
#' @seealso \code{\link[sva]{ComBat}}
#' 
#' @importFrom Biobase exprs pData
#' @importClassesFrom Matrix dgCMatrix
#' @export remove_covariate
#' 
#' @examples
#' # example 1
#' set.seed(1)
#' means <- rep(c(1,2,3), each=3)
#' nrows <- 5
#' e <- matrix(rep(means, nrows), ncol=length(means), byrow=T)
#' e <- e + 
#'     matrix(rnorm(Reduce(`*`, dim(e)), sd=0.3), ncol=length(means), byrow=T)
#' 
#' # add missing values in increasing frequency
#' extreme <- 10 # controls how quickly increases propotion of NAs
#' # 1 - means it will reach 100% by the end
#' # 2 - means only 50% will be missing by the last row
#' # N - is 1/N-th
#' freqs <- (1:nrow(e)-1)/(extreme*(nrow(e)-1))
#' mis <- t(sapply(freqs, rbinom, n=ncol(e), size = 1))
#' 
#' mis[mis == 1] <- NA
#' e[5,8:9] <- NA
#' e[4,4:6] <- NA
#' e <- e + mis
#' image(e) 
#' library("ggplot2"); library("reshape2")
#' ggplot(melt(e), aes(x=Var1, y=Var2, fill=value)) + geom_raster()
#' 
#' # generating factors
#' facs <- gl(length(unique(means)),length(means)/length(unique(means)))
#' # alternative is correction for continuous variable
#' cova <- seq_along(means)
#' 
#' library("Biobase")
#' m <- ExpressionSet(e)
#' pData(m)$pesky <- facs
#' pData(m)$runorder <- cova
#' m2 <- remove_covariate(m, "pesky")
#' m3 <- remove_covariate(m, "runorder")
#' 
#' image(exprs(m))
#' image(exprs(m2))
#' image(exprs(m3))
#' 
#' # Example 2 (real-world)
#' data(cptac_oca)
#' # let's test for iTRAQ_Batch effect
#' res <- eset_lm(oca.set, "y ~ iTRAQ_Batch", "y ~ 1")
#' # not too strong, but there
#' hist(res$p.value, 50)
#' image_msnset(oca.set, facetBy="iTRAQ_Batch")
#' oca.fixed <- remove_covariate(oca.set, "iTRAQ_Batch")
#' res <- eset_lm(oca.fixed, "y ~ iTRAQ_Batch", "y ~ 1")
#' hist(res$p.value, 50)
#' image_msnset(oca.fixed, facetBy="iTRAQ_Batch")

remove_covariate <- function(x, cov_name){
    e <- exprs(x)
    rmns <- apply(e, 1, mean, na.rm=TRUE) # to add later
    cova <- pData(x)[[cov_name]]
    # the reason for splitting into factor vs continuous
    # is that I don't want to rely on (Intercept) reference group in factor
    if(is.factor(cova) || is.character(cova)){
        desmat <- model.matrix( ~ cova + 0)
        suppressWarnings(
            cfs <-
                Reduce(rbind,
                       lapply(1:nrow(e), function(i){
                           cf <- coefficients(lm(e[i,] ~ cova + 0))
                       }))
        )
    }else if(is.numeric(cova)){
        desmat <- model.matrix( ~ cova)
        cfs <-
            Reduce(rbind,
                   lapply(1:nrow(e), function(i){
                       cf <- coefficients(lm(e[i,] ~ cova))
                   }))
    }else{
        stop("unknown type of covariate")
    }
    btch <- t(as.matrix(as(desmat,'dgCMatrix') %*% as(t(cfs),'dgCMatrix')))
    e.nobatch <- e - btch
    # really necessary in case one factor is fully NA
    rmns <- rmns - apply(e.nobatch, 1, mean, na.rm=TRUE)
    #..
    e.backmeans <- sweep(e.nobatch, 1, rmns, '+')
    exprs(x) <- e.backmeans
    return(x)
}



#' @describeIn remove_covariate wrapper around sva::ComBat
#' @importFrom sva ComBat
#' @importFrom magrittr "%>%"
#' @importFrom dplyr select inner_join group_by_at summarize filter pull
#' @importFrom tidyr gather
#' @importFrom tibble rownames_to_column
#' @importFrom Biobase exprs pData
#' @importFrom BiocParallel bpparam
#' @export correct_batch_effect
#' 
#' @param batch_name same thing as covariate name. Using "batch" instead of 
#' "covariate" to keep it consistent with `ComBat`. Must be in pData(x). 
#' At this point it can be only one name.
#' @param least_count_threshold minimum number of feature observations
#' required per batch. The default values is 2, the minimum `ComBat` can 
#' handle safely.
#' @param BPPARAM BiocParallelParam for parallel operation. 
#' Default is bpparam(). Use bpparam("SerialParam") if you want to restrict
#' it to only one thread.
#' @param ... other arguments for \code{\link[sva]{ComBat}}
#' 
#' @examples
#' 
#' # Example for correct_batch_effect
#' data("cptac_oca") # oca.set object
#' plot_pca_v3(oca.set, phenotype = 'Batch')
#' oca.set.2 <- correct_batch_effect(oca.set, batch_name = "Batch")
#' plot_pca_v3(oca.set.2, phenotype = 'Batch')

correct_batch_effect <- function(m, batch_name, 
                                 least_count_threshold = 2,
                                 BPPARAM = bpparam(), 
                                 ...){
    
    # check for problems
    # is one of the batches empty?
    
    
    batch_to_sample <- pData(m) %>%
        select(batch_name) %>%
        rownames_to_column("sample_name")
    
    sufficiently_present_features <- 
        exprs(m) %>%
        as.data.frame() %>%
        rownames_to_column("feature_name") %>%
        gather(sample_name, abundance, -feature_name) %>%
        inner_join(batch_to_sample, by = "sample_name") %>%
        group_by_at(c(batch_name, "feature_name")) %>%
        summarize(cnt = sum(!is.na(abundance))) %>%
        group_by_at("feature_name") %>%
        summarize(min_cnt = min(cnt)) %>%
        filter(min_cnt >= least_count_threshold) %>%
        pull(feature_name)
    
    m <- m[sufficiently_present_features,]
    
    modcombat <- model.matrix(~1, data = select(pData(m), batch_name))
    combat_edata <- ComBat(dat=exprs(m), 
                           batch=pData(m)[,batch_name], 
                           mod=modcombat, 
                           par.prior=FALSE, 
                           prior.plots=TRUE,
                           BPPARAM = BPPARAM,
                           ...)
    exprs(m) <- combat_edata
    return(m)
}







#' @describeIn remove_covariate A flexible batch correction function
#' @export remove_batch_effect
#' 
#' @param ref_level In case a certain factor level should be reference 
#'                  and kept at zero bias. Default is NULL, i.e. none.
#' @param subset_by vector of two strings from varLabels(x). First is the 
#'                  variable name for subsetting the data. Second is the variable value
#'                  to retain.
#' 
#' @examples
#' 
#' data("cptac_oca") # oca.set object
#' plot_pca_v3(oca.set, phenotype = 'Batch')
#' oca.set.2 <- remove_batch_effect(oca.set,
#'                                  batch_name = "Batch", ref_level="X14",
#'                                  subset_by=c("tumor_stage","IIIC"))
#' plot_pca_v3(oca.set.2, phenotype = 'Batch')

remove_batch_effect <- function (x, batch_name, ref_level=NULL, subset_by=c(NULL,NULL)) {
    
    # defining subset of values to compute batch effect on
    idx <- rep(TRUE, ncol(x))
    if(length(subset_by) == 2){
        idx <- pData(x)[[subset_by[1]]] == subset_by[2]
    }
    
    e <- exprs(x)
    cova <- pData(x)[[batch_name]]
    
    if (!is.factor(cova) && !is.character(cova)) {
        stop("The covariate is not a factor or character.")
    }
    
    for(i in 1:nrow(e)){
        # computing biases for each batch on subset [idx] of values
        batch_biases <- tapply(e[i,idx], cova[idx], mean, na.rm=T)
        # If no samples were selected from a certain batch. 
        # Set the correction factor to zero.
        batch_biases[is.na(batch_biases)] <- 0
        # zeroing on reference level (if ref_level provided) & not NA
        if(!is.null(ref_level) && !is.na(as.numeric(batch_biases[ref_level]))) {
            batch_biases <- batch_biases - as.numeric(batch_biases[ref_level])
        }
        # correcting biases
        e[i,] <- e[i,] - as.numeric(batch_biases[cova])
    }
    # re-zero-center
    e <- sweep(e, 1, rowMeans(e, na.rm = T), "-")
    # swap the expression values
    exprs(x) <- e
    return(x)
}
