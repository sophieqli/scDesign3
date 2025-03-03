#' Fit the marginal models
#'
#' \code{fit_marginal} fits the per-feature regression models.
#'
#' The function takes the result from \code{\link{construct_data}} as the input,
#' and fit the regression models for each feature based on users' specification.
#'
#' @param data An object from \code{\link{construct_data}}.
#' @param predictor A string of the predictor for the gam/gamlss model. Default is "gene". This is just a name.
#' @param mu_formula A string of the mu parameter formula. It follows the format of formula in \code{\link[mgcv]{bam}}. Note: if the formula has multiple smoothers (\code{s()}) (we do not recommend this), please put the one with largest k (most complex one) as the first one. 
#' @param sigma_formula A string of the sigma parameter formula
#' @param family_use A string or a vector of strings of the marginal distribution.
#' Must be one of 'binomial', 'poisson', 'nb', 'zip', 'zinb' or 'gaussian', which represent 'poisson distribution',
#' 'negative binomial distribution', 'zero-inflated poisson distribution', 'zero-inflated negative binomial distribution',
#' and 'gaussian distribution' respectively.
#' @param n_cores An integer. The number of cores to use.
#' @param usebam A logic variable. If use \code{\link[mgcv]{bam}} for acceleration.
#' @param edf_flexible A logic variable. It uses simpler model to accelerate the marginal fitting with a mild loss of accuracy. If TRUE, the fitted regression model will use the fitted relationship between Gini coefficient and the effective degrees of freedom on a random selected gene sets. Default is FALSE.
#' @param parallelization A string indicating the specific parallelization function to use.
#' Must be one of 'mcmapply', 'bpmapply', or 'pbmcmapply', which corresponds to the parallelization function in the package
#' \code{parallel},\code{BiocParallel}, and \code{pbmcapply} respectively. The default value is 'mcmapply'.
#' @param BPPARAM A \code{MulticoreParam} object or NULL. When the parameter parallelization = 'mcmapply' or 'pbmcmapply',
#' this parameter must be NULL. When the parameter parallelization = 'bpmapply',  this parameter must be one of the
#' \code{MulticoreParam} object offered by the package 'BiocParallel. The default value is NULL.
#' @param trace A logic variable. If TRUE, the warning/error log and runtime for gam/gamlss will be returned.
#' will be returned, FALSE otherwise. Default is FALSE.
#' @param simplify A logic variable. If TRUE, the fitted regression model will only keep the essential contains for \code{predict}. Default is FALSE.
#' @param filter_cells A logic variable. If TRUE, when all covariates used for fitting the GAM/GAMLSS model are categorical, the code will check each unique combination of categories and remove cells in that category if it has all zero gene expression for each fitted gene.
#' @return A list of fitted regression models. The length is equal to the total feature number.
#' @examples
#'   data(example_sce)
#'   my_data <- construct_data(
#'   sce = example_sce,
#'   assay_use = "counts",
#'   celltype = "cell_type",
#'   pseudotime = "pseudotime",
#'   spatial = NULL,
#'   other_covariates = NULL,
#'   corr_by = "1"
#'   )
#'   my_marginal <- fit_marginal(
#'   data = my_data,
#'   mu_formula = "s(pseudotime, bs = 'cr', k = 10)",
#'   sigma_formula = "1",
#'   family_use = "nb",
#'   n_cores = 1,
#'   usebam = FALSE
#'   )
#'
#' @export fit_marginal
#'


library(MASS)

myDEBUG = FALSE

fit_marginal <- function(data,
                         predictor = "gene", ## Fix this later.
                         mu_formula,
                         sigma_formula,
                         family_use,
                         n_cores,
                         usebam = FALSE,
                         edf_flexible = FALSE,
                         parallelization = "mcmapply",
                         BPPARAM = NULL,
                         trace = FALSE, 
                         simplify = FALSE,
                         filter_cells = FALSE) {
  count_mat <-  data$count_mat
  dat_cov <- data$dat
  filtered_gene <- data$filtered_gene
  feature_names <- colnames(count_mat)
  

  
  # Extract K from mu formula
  matches <- regexpr("k\\s*=\\s*([0-9]+)", mu_formula, perl = TRUE)
  extracted_value <- regmatches(mu_formula, matches)
  extracted_K <- as.numeric(sub("k\\s*=\\s*", "", extracted_value))
  if(identical(extracted_K, numeric(0))) {
    extracted_K <- 0
  }
  
  # Randomly select genes for edf fitting
  num <- 100
  if(dim(count_mat)[2] > num & extracted_K >= 200 & edf_flexible == TRUE){
    edf_fitting <- TRUE
    
    # genes for fitting edf-gini relationship
    edf_gini_genes <- sample(seq_len(dim(count_mat)[2]), num)
    edf_gini_count_mat <-  count_mat[,edf_gini_genes]
    edf_gini_feature_names <- feature_names[edf_gini_genes]
    
    # genes for flexible edf
    edf_flexible_genes <- seq_len(dim(count_mat)[2])[-edf_gini_genes]
    edf_flexible_count_mat <- count_mat[,-edf_gini_genes]
    edf_flexible_feature_names <- feature_names[-edf_gini_genes]
    
  }else{
    edf_fitting <- FALSE
  }
  
  
  ## Check family_use
  if(length(family_use) == 1) {
    if(edf_fitting == TRUE) {
      edf_gini_family_use <- rep(family_use, length(edf_gini_feature_names))
      edf_flexible_family_use <- rep(family_use, length(edf_flexible_feature_names))
    }
    family_use <- rep(family_use, length(feature_names))
  }
  if(length(family_use) != length(feature_names)) {
    stop("The family_use must be either a single string or a vector with the same length as all features!")
  }
  
  
  fit_model_func <- function(gene,
                             family_gene,
                             dat_use,
                             #mgcv_formula,
                             mu_formula,
                             sigma_formula,
                             predictor,
                             count_mat,
                             edf=NULL
  ) {
    
    if(!is.null(edf)){
      mu_formula_ex <- sub("(k\\s*=).*", "\\1", mu_formula)
      mu_formula = paste0(mu_formula_ex, round(edf[[gene]]), ")")
    }
    
    mgcv_formula <-
      stats::formula(paste0(predictor, "~", mu_formula))
    
    ## If use the mgcv s() smoother
    mu_mgcvform <- grepl("s\\(", mu_formula) | grepl("te\\(", mu_formula)
    
    ## If use bam to fit marginal distribution
    usebam <- usebam & mu_mgcvform ## If no smoothing terms, no need to to use bam.
    if(usebam){
      fitfunc = mgcv::bam
    }else{
      fitfunc = mgcv::gam
    }
    
    if (mu_mgcvform) {
      terms <- attr(stats::terms(mgcv_formula), "term.labels")
      terms_smooth <- terms[which(grepl("s\\(", terms))] 
      
      if(usebam){
        terms_smooth_update <- sapply(terms_smooth, function(x){paste0("ba(~", x, ", method = 'fREML', gc.level = 0, discrete = TRUE)")})
        if(length(terms_smooth) == length(terms)){## only contain smooth terms
          mu_formula <-
            stats::formula(paste0(predictor, "~", paste0(terms_smooth_update, collapse = "+")))
        }else{
          terms_linear <- terms[which(!grepl("s\\(", terms))] 
          terms_update <- c(terms_linear, terms_smooth_update)
          mu_formula <-
            stats::formula(paste0(predictor, "~", paste0(terms_update, collapse = "+")))
        }
      }else{
        terms_smooth_update <- sapply(terms_smooth, function(x){paste0("ga(~", x, ", method = 'REML')")})
        if(length(terms_smooth) == length(terms)){## only contain smooth terms
          mu_formula <-
            stats::formula(paste0(predictor, "~", paste0(terms_smooth_update, collapse = "+")))
        }else{
          terms_linear <- terms[which(!grepl("s\\(", terms))] 
          terms_update <- c(terms_linear, terms_smooth_update)
          mu_formula <-
            stats::formula(paste0(predictor, "~", paste0(terms_update, collapse = "+")))
        }
      }
    }
    else {
      mu_formula <- stats::formula(paste0(predictor, "~", mu_formula))
    }
    
    sigma_mgcvform <- grepl("s\\(", sigma_formula) | grepl("te\\(", sigma_formula)
    if (sigma_mgcvform) {
      temp_sigma_formula <- stats::formula(paste0(predictor, "~", sigma_formula))
      terms <- attr(stats::terms(temp_sigma_formula), "term.labels")
      terms_smooth <- terms[which(grepl("s\\(", terms))]
      if(usebam){
        terms_smooth_update <- sapply(terms_smooth, function(x){paste0("ba(~", x, ", method = 'fREML', gc.level = 0, discrete = TRUE)")})
        if(length(terms_smooth) == length(terms)){## only contain smooth terms
          sigma_formula <-
            stats::formula(paste0("~", paste0(terms_smooth_update, collapse = "+")))
        }else{
          terms_linear <- terms[which(!grepl("s\\(", terms))] 
          terms_update <- c(terms_linear, terms_smooth_update)
          sigma_formula <-
            stats::formula(paste0("~", paste0(terms_update, collapse = "+")))
        }
      }else{
        terms_smooth_update <- sapply(terms_smooth, function(x){paste0("ga(~", x, ", method = 'REML')")})
        if(length(terms_smooth) == length(terms)){## only contain smooth terms
          sigma_formula <-
            stats::formula(paste0("~", paste0(terms_smooth_update, collapse = "+")))
        }else{
          terms_linear <- terms[which(!grepl("s\\(", terms))] 
          terms_update <- c(terms_linear, terms_smooth_update)
          sigma_formula <-
            stats::formula(paste0("~", paste0(terms_update, collapse = "+")))
        }
      }
      
    } else {
      sigma_formula <- stats::formula(paste0("~", sigma_formula))
    }
    
    
    ## Add gene expr
    dat_use$gene <- count_mat[, gene]
    
    ## For error/warning logging
    add_log <- function(function_name, type, message) {
      new_l <- logs
      new_log <- list(function_name = function_name,
                      type = type,
                      message =  message)
      new_l[[length(new_l) + 1]]  <- new_log
      logs <<- new_l
    }
    
    logs <- list()
    ## Don't fit marginal if gene only have two or less non-zero expression
    if(!is.null(filtered_gene) & gene %in% filtered_gene){
      add_log("fit_marginal","warning", paste0(gene, "is expressed in too few cells."))
      return(list(fit = NA, warning = logs, time = c(NA,NA)))
    }
    
    if(filter_cells){
      all_covariates <- all.vars(mgcv_formula)[-1]
      dat_cova <- dat_use[, all_covariates]
      check_factor <- all(sapply(dat_cova,is.factor))
      if (length(all_covariates) > 0 & check_factor){
        remove_idx_list <- lapply(all_covariates, function(x){
          curr_x <- tapply(dat_use$gene, dat_use[,x], sum)
          zero_group <- which(curr_x==0)
          if(length(zero_group) == 0){
            return(list(idx = NA, changeFormula = FALSE))
          }else{
            type <- names(curr_x)[zero_group]
            if(length(type) == length(unique(dat_use[,x])) - 1){
              return(list(idx = NA, changeFormula = TRUE))
            }
            return(list(idx = which(dat_use[,x] %in% type), changeFormula = FALSE))
          }
          
        })
        names(remove_idx_list) <- all_covariates
        remove_idx <- lapply(remove_idx_list, function(x)x$idx)
        remove_cell <- unlist(remove_idx)
        if(all(is.na(remove_cell))){
          remove_cell <- NA
        }else{
          remove_cell <- unique(stats::na.omit(remove_cell))
        }
        if(length(remove_cell) > 0 && !any(is.na(remove_cell))){
          dat_use <- dat_use[-remove_cell,]
        }
        
        changeFormula <-  sapply(remove_idx_list, function(x)x$changeFormula)
        if(length(which(changeFormula)) > 0){
          changeVars <- names(which(changeFormula))
          formulaUpdate <- paste0(changeVars, collapse = "-")
          mgcv_formula <- stats::update.formula(mgcv_formula, stats::as.formula(paste0("~.-",formulaUpdate)))
          mu_formula <- stats::update.formula(mu_formula, stats::as.formula(paste0("~.-",formulaUpdate)))
          sigmaVars <- which(changeVars %in% as.character(sigma_formula))
          if(length(sigmaVars) > 0){
            formulaUpdate <- paste0(changeVars[sigmaVars], collapse = "-")
          }
          sigma_formula = stats::update.formula(sigma_formula, stats::as.formula(paste0("~.-",formulaUpdate)))
        }
        
      }else{
        remove_cell <- NA
      }
    }else{
      remove_cell <- NA
    }
    
    
    time_list <- c(NA,NA)

    #set all the fitter parameters and check family gene is a valid one
    all_gene_family = c( "binomial", "poisson", "gaussian", "nb", "zip", "zinb" )
    if( ! family_gene %in% all_gene_family ) {
      stop("The regression distribution must be one of gaussian, poisson, nb, zip or zinb!")
    }
    mgcv_family = list( 
      "binomial" = "binomial",
      "poisson" =  "poisson", 
      "gaussian" = "gaussian", 
      "nb" = "nb", 
      "zip" = "poisson", 
      "zinb" = "nb" 
    )
    gamlss_family = list( 
      "binomial" = gamlss.dist::BI, 
      "poisson" = gamlss.dist::PO, 
      "gaussian" = gamlss.dist::NO, 
      "nb" = gamlss.dist::NBI,
      "zip" = gamlss.dist::ZIP, 
      "zinb" = gamlss.dist::ZINBI
    )
    
    print( gene )
    if( mu_formula == 'gene ~ cell_type' || mu_formula == 'gene ~ cell_type + batch') {
      #print("going case 1")
      #define the fit function for each split of the data. 
      #return: list( mu, sigma )
      fit_each_split = function( dat_split ) {
        glm.nb.fit = NULL
        glm.nb.fit <- withCallingHandlers(
          tryCatch({
            model_nb <-glm.nb(gene ~ 1, data = dat_split)
            time <- as.numeric(end.time - start.time)
            print("glm.nb fit")
            model_nb 
          }, error=function(e) {
            add_log("glm.nb","error", toString(e))
            NULL
          }), warning=function(w) {
            add_log("glm.nb","warning", toString(w))
          })

          if( is.null(glm.nb.fit) ) {
            mu = dat_split$gene
            names(mu) = rownames(dat_split)
            sigma = mu
            sigma[] = 0
          } else {
            mu = fitted( model_nb )
            sigma = 1.0 / summary( model_nb )$theta
            sigma = rep(sigma, length(mu) )
          }
          return( list( 'mu' = mu, 'sigma' = sigma ) )
      }

      if( mu_formula == 'gene ~ cell_type' ) {
        res = lapply( split( dat_use, dat_use$cell_type), fit_each_split )
      } else if( mu_formula == 'gene ~ cell_type + batch' ) {
        res = lapply( split( dat_use, list( dat_use$cell_type, dat_use$batch ) ), fit_each_split )
      } else {
        print("unknown formula for mu")
        exit(1)
      }
      mean_vec = c(); theta_vec = c()
      for(s in res) {
        mean_vec = c(mean_vec, s[['mu']] ); 
        theta_vec = c(theta_vec, s[['sigma']] )
      }
      mean_vec = mean_vec[match(rownames(dat_use), names(mean_vec)) ]
      theta_vec = theta_vec[match(rownames(dat_use), names(theta_vec)) ]
      zero_vec <- rep( 0, length(mean_vec))
      stopifnot( identical( names(mean_vec), rownames(dat_use) ));
      #end if mu_formula is cell_type + batch

    } else {

      # formula is not "gene ~ cell_type + batch", now we fit gam and gamlss 
      #print("going case 2")
      mgcv.fit <- withCallingHandlers(
        tryCatch({
          start.time <- Sys.time()
          res <-fitfunc(formula = mgcv_formula, data = dat_use, family = mgcv_family[[family_gene]], discrete = usebam)
          end.time <- Sys.time()
          time <- as.numeric(end.time - start.time)
          time_list[1] <- time
          res
        }, error=function(e) {
          add_log("gam","error", toString(e))
          NULL
        }), warning=function(w) {
          add_log("gam","warning", toString(w))
        })

      #print( mu_formula )
      #print( sigma_formula )
      #print( colnames(dat_use))
      #print( dim(dat_use))
      if( family_gene == "zip" || family_gene == "zinb" || sigma_formula != "~1") {
        gamlss.fit <- withCallingHandlers(
          tryCatch({
            start.time = Sys.time()
            res <- gamlss::gamlss(
              formula = mu_formula,
              sigma.formula = sigma_formula,
              data = dat_use,
              family = gamlss_family[[family_gene]],
              #family = gamlss.dist::NBI,
              control = gamlss::gamlss.control(trace = FALSE,  c.crit = 0.1)
            )
            end.time = Sys.time()
            time = as.numeric(end.time - start.time)
            time_list[2] <- time
            res
          }, error=function(e) {
            add_log("gamlss","error", toString(e))
            NULL
          }), warning=function(w) {
            add_log("gamlss","warning", toString(w))
          })
      } else {
        gamlss.fit <- NULL
      }

      ## Check if gamlss is fitted.
      if (!"gamlss" %in% class(gamlss.fit)) {
        if (sigma_formula != "~1") {
          message(paste0(gene, " uses mgcv::gam due to gamlss's error!"))
          ## gamlss.fit contains warning message
          if(!is.null(gamlss.fit)){
            ## check whether gam has warning messages
            if(is.null(warn)){
              warn = gamlss.fit
            }else{
              warn = c(warn, gamlss.fit)
            }
          }
        }
        fit <- mgcv.fit
      } else {
        #mean_vec <- stats::predict(gamlss.fit, type = "response", what = "mu", data = dat_use)
        #theta_vec <- stats::predict(gamlss.fit, type = "response", what = "sigma", data = dat_use)
        mean_vec <- fitted(gamlss.fit, type = "response", what = "mu")
        theta_vec <- fitted(gamlss.fit, type = "response", what = "sigma")

        if_infinite <- (sum(is.infinite(mean_vec + theta_vec)) > 0)
        if_overmax <- (max(mean_vec, na.rm = TRUE) > 10* max(dat_use$gene, na.rm = TRUE))
        if(family_gene %in% c("nb","zinb")){
          #if_overdisp <- (min(theta_vec, na.rm = TRUE) < 1/ 1000)
          if_overdisp <- (max(theta_vec, na.rm = TRUE) > 1000)
          
        }else{
          if_overdisp <- FALSE
        }
        
        if (if_infinite | if_overmax | if_overdisp) {
          add_log("fit_marginal","warning", paste0(gene, " gamlss returns abnormal fitting values!"))
          #message(paste0(gene, " gamlss returns abnormal fitting values!"))
          fit <- mgcv.fit
        } else if (stats::AIC(mgcv.fit) - stats::AIC(gamlss.fit) < -Inf) {
          message(paste0(
            gene,
            "'s gamlss AIC is not signifincantly smaller than gam!"
          ))
          fit <- mgcv.fit
        }
        else {
          fit <- gamlss.fit
        }
      }

      #mean_vec  <- stats::predict(fit, type = "response", what = "mu", data = dat_use)
      #theta_vec <- stats::predict(fit, type = "response", what = "sigma", data = dat_use)
      mean_vec <- fitted(fit, type = "response", what = "mu"); names(mean_vec) = rownames(dat_use)
      theta_vec <- fitted(fit, type = "response", what = "sigma"); names(theta_vec) = rownames(dat_use)
      zero_vec  <- rep( 0, length(mean_vec)); names(zero_vec) = rownames(dat_use)
    }
    
    if(trace){
      return(list(warning = logs, 
                  time = time_list, 
                  removed_cell = remove_cell, 
                  mean_vec = mean_vec, 
                  theta_vec = theta_vec, 
                  zero_vec = zero_vec ))
    }
    return(list(removed_cell = remove_cell,
                mean_vec = mean_vec, 
                theta_vec = theta_vec, 
                zero_vec = zero_vec ))
  }
  
  paraFunc <- parallel::mcmapply
  if(.Platform$OS.type == "windows"){
    BPPARAM <- BiocParallel::SnowParam()
    parallelization <- "bpmapply"
  }
  if(parallelization == "bpmapply"){
    paraFunc <- BiocParallel::bpmapply
  }
  if(parallelization == "pbmcmapply"){
    paraFunc <- pbmcapply::pbmcmapply
  }
  # If not using edf flexible fitting
  if(edf_fitting==FALSE){
    if(parallelization == "bpmapply"){
      if(class(BPPARAM)[1] != "SerialParam"){
        BPPARAM$workers <- n_cores
      }
      if( myDEBUG ) {
        model_fit <- fit_model_func( gene = feature_names[1],
                                             family_gene = family_use[1],
                                             dat_use = dat_cov,
                                                             #mgcv_formula = mgcv_formula,
                                                             mu_formula = mu_formula,
                                                             sigma_formula = sigma_formula,
                                                             predictor = predictor,
                                                             count_mat = count_mat)
      } else {
        model_fit <- suppressMessages(paraFunc(fit_model_func, gene = feature_names,
                                             family_gene = family_use,
                                             MoreArgs = list(dat_use = dat_cov,
                                                             #mgcv_formula = mgcv_formula,
                                                             mu_formula = mu_formula,
                                                             sigma_formula = sigma_formula,
                                                             predictor = predictor,
                                                             count_mat = count_mat),
                                             SIMPLIFY = FALSE, BPPARAM = BPPARAM))
      }
    }else{
      if( myDEBUG ) {
        model_fit <- fit_model_func( gene = feature_names[1],
                                             family_gene = family_use[1],
                                             dat_use = dat_cov,
                                                             #mgcv_formula = mgcv_formula,
                                                             mu_formula = mu_formula,
                                                             sigma_formula = sigma_formula,
                                                             predictor = predictor,
                                                             count_mat = count_mat)
      } else {
        model_fit <-  suppressMessages(paraFunc(fit_model_func, gene = feature_names,
                                              family_gene = family_use,
                                              mc.cores = n_cores,
                                              MoreArgs = list(dat_use = dat_cov,
                                                              #mgcv_formula = mgcv_formula,
                                                              mu_formula = mu_formula,
                                                              sigma_formula = sigma_formula,
                                                              predictor = predictor,
                                                              count_mat = count_mat),
                                              SIMPLIFY = FALSE))
      }
    }
  }else{ 
    # If using edf flexible fitting
    
    if(parallelization == "bpmapply"){
      if(class(BPPARAM)[1] != "SerialParam"){
        BPPARAM$workers <- n_cores
      }
      # Fit model to selected edf_gini_genes 
      model_fit_edf_gini <- suppressMessages(paraFunc(fit_model_func, gene = edf_gini_feature_names,
                                                      family_gene = edf_gini_family_use,
                                                      MoreArgs = list(dat_use = dat_cov,
                                                                      #mgcv_formula = mgcv_formula,
                                                                      mu_formula = mu_formula,
                                                                      sigma_formula = sigma_formula,
                                                                      predictor = predictor,
                                                                      count_mat = edf_gini_count_mat),
                                                      SIMPLIFY = FALSE, BPPARAM = BPPARAM))
    }else{
      
      # Fit model to selected edf_gini_genes
      model_fit_edf_gini <-  suppressMessages(paraFunc(fit_model_func, gene = edf_gini_feature_names,
                                                       family_gene = edf_gini_family_use,
                                                       mc.cores = n_cores,
                                                       MoreArgs = list(dat_use = dat_cov,
                                                                       #mgcv_formula = mgcv_formula,
                                                                       mu_formula = mu_formula,
                                                                       sigma_formula = sigma_formula,
                                                                       predictor = predictor,
                                                                       count_mat = edf_gini_count_mat),
                                                       SIMPLIFY = FALSE))
    }
    
    
    # Extract the fitted edf
    edf <- rep(NA, length(model_fit_edf_gini))
    for(i in 1:length(model_fit_edf_gini)){
      res_ind <- model_fit_edf_gini[i]
      if(lengths(res_ind)==2){
        res_ind <- res_ind[[names(res_ind)]]
        edf[i] <- sum(res_ind$fit$edf)
      }
    }
    
    # Fit a edf-gini relationship for edf_gini_genes
    edf_gini_count_gini <- apply(log(edf_gini_count_mat+1), MARGIN=2, FUN=gini)
    edf_gini_df <- data.frame(edf=edf, gini=edf_gini_count_gini)
    lm_edf_gini <- stats::lm(edf~gini, data=edf_gini_df)
    # Upper bound for the lm coef
    #coef <- confint(lm_edf_gini)[,2]
    
    
    # Predict edf for edf_flexible_genes
    edf_flexible_count_gini <- apply(log(edf_flexible_count_mat+1), MARGIN=2, FUN=gini)
    edf_flexible_df <- data.frame(gini=edf_flexible_count_gini)
    edf_flexible_predicted <- stats::predict(lm_edf_gini, edf_flexible_df, se.fit = TRUE, interval = "confidence", level = 0.95)
    edf_flexible_predicted_upr <- edf_flexible_predicted$fit[,3]
    
    
    # Fit again for the rest genes
    if(parallelization == "bpmapply"){
      if(class(BPPARAM)[1] != "SerialParam"){
        BPPARAM$workers <- n_cores
      }
      model_fit_edf_flexible <- suppressMessages(paraFunc(fit_model_func, gene = edf_flexible_feature_names,
                                                          family_gene = edf_flexible_family_use,
                                                          MoreArgs = list(dat_use = dat_cov,
                                                                          #mgcv_formula = mgcv_formula,
                                                                          mu_formula = mu_formula,
                                                                          sigma_formula = sigma_formula,
                                                                          predictor = predictor,
                                                                          count_mat = edf_flexible_count_mat,
                                                                          edf=edf_flexible_predicted_upr),
                                                          SIMPLIFY = FALSE, BPPARAM = BPPARAM))
    }else{
      model_fit_edf_flexible <-  suppressMessages(paraFunc(fit_model_func, gene = edf_flexible_feature_names,
                                                           family_gene = edf_flexible_family_use,
                                                           mc.cores = n_cores,
                                                           MoreArgs = list(dat_use = dat_cov,
                                                                           #mgcv_formula = mgcv_formula,
                                                                           mu_formula = mu_formula,
                                                                           sigma_formula = sigma_formula,
                                                                           predictor = predictor,
                                                                           count_mat = edf_flexible_count_mat,
                                                                           edf=edf_flexible_predicted_upr),
                                                           SIMPLIFY = FALSE))
    }
    
    
    # Combine model_fit_edf_gini and model_fit_edf_flexible
    model_fit <- vector(mode = "list", length = length(feature_names))
    names(model_fit) <- feature_names
    
    # Populate the new list based on indices:
    for (index in names(model_fit_edf_gini)) {
      model_fit[[index]] <- model_fit_edf_gini[[index]]
    }
    for (index in names(model_fit_edf_flexible)) {
      model_fit[[index]] <- model_fit_edf_flexible[[index]]
    }
  } 
  
  # if(!is.null(model_fit$warning)) {
  #   #stop("Model has warning!")
  #   model_fit <- model_fit$value
  # }
  return(model_fit)
}

simplify_fit <- function(cm) {
  ## This function is modified from https://win-vector.com/2014/05/30/trimming-the-fat-from-glm-models-in-r/
  cm$y = c()
  #cm$model = c()
  
  cm$residuals = c()
  cm$fitted.values = c()
  cm$effects = c()
  cm$qr$qr = c()  
  cm$linear.predictors = c()
  cm$weights = c()
  cm$prior.weights = c()
  cm$data = c()
  
  #cm$mu.x = c()
  #cm$sigma.x = c()
  #cm$nu.x = c()
  
  #cm$family$variance = c()
  #cm$family$dev.resids = c()
  #cm$family$aic = c()
  #cm$family$validmu = c()
  #cm$family$simulate = c()
  attr(cm$terms,".Environment") = c()
  attr(cm$formula,".Environment") = c()
  
  attr(cm$mu.terms,".Environment") = c()
  attr(cm$mu.formula,".Environment") = c()
  
  attr(cm$sigma.terms,".Environment") = c()
  attr(cm$sigma.formula,".Environment") = c()
  
  attr(cm$nu.terms,".Environment") = c()
  attr(cm$nu.formula,".Environment") = c()
  cm
}

## Function from R package reldist by Dr. Mark S. Handcock
gini <- function(x, weights=rep(1,length=length(x))){
  ox <- order(x)
  x <- x[ox]
  weights <- weights[ox]/sum(weights)
  p <- cumsum(weights)
  nu <- cumsum(weights*x)
  n <- length(nu)
  nu <- nu / nu[n]
  sum(nu[-1]*p[-n]) - sum(nu[-n]*p[-1])
}


