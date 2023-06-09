# ----setup, echo=FALSE, cache=FALSE------------------------------------------------------------------------------------------------------
# Set working directory
setwd("../../data/raw/GSE47460/")
# Set seet (reproducibility)
# set.seed(1234)


## ----------------------------------------------------------------------------------------------------------------------------------------
# Required packages
library(tidyverse)
library(tidymodels)
library(Biobase)
library(vip)
library(sva)
library(themis)
library(glmnet)
library(stacks)

## ----------------------------------------------------------------------------------------------------------------------------------------
# Read dea cutoffs an input eset object from command line
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2) {
  stop("Please provide one arguments.")
} else if (length(args) == 2) {
  num_iterations <- args[1]
  num_genes <- args[2]
}

# ----------------------------------------------------------------------------------------------------------------------------------------
# Upload data
ini <- Sys.time()

# load("../../ExpressionSetObjects/eset.Rda")

# Load Train and Test set
## Train
load("../../ML_out/two_class/copd_ctrl_train.Rda")
## Test
load("../../ML_out/two_class/copd_ctrl_test.Rda")

## ----------------------------------------------------------------------------------------------------------------------------------------
# ML models
## ----------------------------------------------------------------------------------------------------------------------------------------

# Check dimensions
dim(copd_ctrl_train)
dim(copd_ctrl_test)

# Metrics
auc_acc_sens_spec <- metric_set(accuracy, yardstick::sens,  yardstick::spec,
                                precision, roc_auc, mn_log_loss)
acc_sens_spec <- metric_set(accuracy, yardstick::sens, yardstick::spec, precision)
auc_loss <- metric_set(roc_auc, mn_log_loss)

ML_models <- function(copd_ctrl_train_mrmr){

  # Folds
  copd_ctrl_folds <- vfold_cv(copd_ctrl_train_mrmr)

  # RECIPES
  ## Recipe without normalization step
  copd_ctrl_rec <- recipe(dis_condition ~. , data = copd_ctrl_train_mrmr) %>%
    step_BoxCox(all_numeric_predictors()) %>%
    step_corr(all_numeric_predictors(), threshold = .85) %>% # for correlated variables
    step_downsample(dis_condition)   # for class imbalance
  juiced <- juice(prep(copd_ctrl_rec))

  ## Recipe for models that required normalized data: en, knn
  copd_ctrl_normalized_rec <- recipe(dis_condition ~. , data = copd_ctrl_train_mrmr) %>%
    step_BoxCox(all_numeric_predictors()) %>%
    step_corr(all_numeric_predictors(), threshold = .85) %>%  # for correlated variables
    step_downsample(dis_condition) %>%
    step_normalize(all_predictors())
  juiced_normalized <- juice(prep(copd_ctrl_normalized_rec)) # apply the pre-processing steps to datasets

  # Control
  ctrl_res <- control_resamples(save_pred = TRUE, save_workflow = TRUE, verbose = TRUE,)
  ctrl_bayes <- control_bayes(no_improve = 15, verbose = TRUE, save_pred = TRUE, save_workflow = TRUE)

  # MODEL SPECIFICATIONS & WORKFLOW
  ## Random Forest
  rf_spec <- rand_forest(
    mtry = tune(), # num of predictor vbles to sample in each split of the tree
    trees = 1000,  # num of trees
    min_n = tune() # minimum node size
  ) %>%
    set_mode("classification") %>%
    set_engine("ranger", oob.error = TRUE, importance = "impurity",seed = 1234)

  rf_wf <- workflow() %>%
    add_recipe(copd_ctrl_rec) %>%
    add_model(rf_spec)

  ## Support Vector Machines: radial
  svm_r_spec <- svm_rbf(
    cost = tune(),
    rbf_sigma = tune()
  ) %>%
    set_engine("kernlab") %>%
    set_mode("classification")

  svm_r_wf <- workflow() %>%
    add_recipe(copd_ctrl_normalized_rec) %>%
    add_model(svm_r_spec)

  ## Support Vector Machines: polynomial
  svm_p_spec <-
    svm_poly(cost = tune(), degree = tune()) %>%
    set_engine("kernlab") %>%
    set_mode("classification")

  svm_p_wf <- workflow() %>%
    add_recipe(copd_ctrl_normalized_rec) %>%
    add_model(svm_p_spec)

  ## Penalized Regression Model
  en_spec <- logistic_reg(penalty = tune(),
                          mixture = tune()) %>%
    set_engine("glmnet") %>%
    set_mode("classification")

  en_wf <- workflow() %>%
    add_recipe(copd_ctrl_normalized_rec) %>%
    add_model(en_spec)

  ## k-Nearest Neighbours
  knn_spec <- nearest_neighbor(
    neighbors = tune(),
    dist_power = tune(),
    weight_func = tune()) %>%
    set_engine("kknn") %>%
    set_mode("classification")

  knn_wf <- workflow() %>%
    add_recipe(copd_ctrl_normalized_rec) %>%
    add_model(knn_spec)

  ## XGBoost
  xgb_spec <- boost_tree(
      trees = 1000,
      tree_depth = tune(), min_n = tune(),
      loss_reduction = tune(),
      sample_size = tune(), mtry = tune(),
      learn_rate = tune()
    ) %>%
      set_engine("xgboost") %>%
      set_mode("classification")

    xgb_wf <- workflow() %>%
        add_recipe(copd_ctrl_rec) %>%
        add_model(xgb_spec)

  # TUNING
  ## Random Forest
  ini_rf <- Sys.time()

  parameters_rf <- parameters(rf_spec)
  #' It is necessary to finalize the range of values of mtry() that depend on the
  #' number of columns
  parameters_rf <- rf_spec %>% parameters() %>% finalize(copd_ctrl_pred)

  # load("../../ML_out/two_class/cv_simple/res_objects/rf_res.Rda")

  rf_res <- tune_bayes(
    rf_wf,  # add workflow
    resamples = copd_ctrl_folds,
    param_info = parameters_rf,
    initial = 6, # This could also be a grid search
    # initial = rf_res,
    iter = 25,
    metrics = auc_acc_sens_spec,
    control = ctrl_bayes
  )

  best_loss_rf <- select_best(rf_res, "mn_log_loss") # Best based on mn_log_loss
  best_accuracy_rf <- select_best(rf_res, "accuracy") # Best based on accuracy
  best_sens_rf <- select_best(rf_res, "sens") # Best based on sensitivity
  best_spec_rf <- select_best(rf_res, "spec") # Best based on specificity
  best_auc_rf <- select_best(rf_res, "roc_auc") # Best based on auc
  best_precision_rf <- select_best(rf_res, "precision") # Best based on precision

  fin_rf <- Sys.time()

  ## Support Vector Machines: radial, runtime_in_seconds()
  ini_svm_r <- Sys.time()
  parameters_r_svm <- parameters(svm_r_spec)

  # load("../../ML_out/two_class/cv_simple/res_objects/svm_r_res.Rda")

  svm_r_res <- tune_bayes(
    svm_r_wf,  # add workflow
    resamples = copd_ctrl_folds,
    param_info = parameters_r_svm,
    initial = 6, # This could also be a grid search
    # initial = svm_r_res,
    iter = 25,
    metrics = auc_acc_sens_spec,
    control = ctrl_bayes
  )

  best_loss_svm_r <- select_best(svm_r_res, "mn_log_loss") # Best based on log_loss
  best_accuracy_svm_r <- select_best(svm_r_res, "accuracy") # Best based on accuracy
  best_sens_svm_r <- select_best(svm_r_res, "sens") # Best based on sensitivity
  best_spec_svm_r <- select_best(svm_r_res, "spec") # Best based on specificity
  best_auc_svm_r <- select_best(svm_r_res, "roc_auc") # Best based on auc
  best_precision_svm_r <- select_best(svm_r_res, "precision") # Best based on precsion

  fin_svm_r <- Sys.time()

  ## Support Vector Machines: polynomial
  ini_svm_p <- Sys.time()
  parameters_p_svm <- parameters(svm_p_spec)

  # load("../../ML_out/two_class/cv_simple/res_objects/svm_p_res.Rda")

  svm_p_res <- tune_bayes(
    svm_p_wf,  # add workflow
    resamples = copd_ctrl_folds,
    param_info = parameters_p_svm,
    initial = 6, # This could also be a grid search
    # initial = svm_p_res,
    iter = 25,
    metrics = auc_acc_sens_spec,
    control = ctrl_bayes
  )

  best_loss_svm_p <- select_best(svm_p_res, "mn_log_loss") # Best based on loss
  best_accuracy_svm_p <- select_best(svm_p_res, "accuracy") # Best based on accuracy
  best_sens_svm_p <- select_best(svm_p_res, "sens") # Best based on sensitivity
  best_spec_svm_p <- select_best(svm_p_res, "spec") # Best based on specificity
  best_auc_svm_p <- select_best(svm_p_res, "roc_auc") # Best based on auc
  best_precision_svm_p <- select_best(svm_p_res, "precision") # Best based on precision

  fin_svm_p <- Sys.time()

  ## Penalized Regression Model
  ini_en <- Sys.time()
  parameters_en <- parameters(en_spec)

  # load("../../ML_out/two_class/cv_simple/res_objects/en_res.Rda")

  en_res <- tune_bayes(
    en_wf,  # add workflow
    resamples = copd_ctrl_folds,
    param_info = parameters_en,
    initial = 6, # This could also be a grid search
    # initial = en_res,
    iter = 25,
    metrics = auc_acc_sens_spec,
    control = ctrl_bayes
  )

  best_loss_en <- select_best(en_res, "mn_log_loss")   # Best based on loss
  best_accuracy_en <- select_best(en_res, "accuracy") # Best based on accuracy
  best_sens_en <- select_best(en_res, "sens") # Best based on sensitivity
  best_spec_en <- select_best(en_res, "spec") # Best based on specificity
  best_auc_en <- select_best(en_res, "roc_auc") # Best based on auc
  best_precision_en <- select_best(en_res, "precision") # Best based on precision

  fin_en <- Sys.time()

  ## k-Nearest Neighbours
  ini_knn <- Sys.time()
  parameters_knn <- parameters(knn_spec)

  # load("../../ML_out/two_class/cv_simple/res_objects/knn_res.Rda")

  knn_res <- tune_bayes(
    knn_wf,  # add workflow
    resamples = copd_ctrl_folds,
    param_info = parameters_knn,
     initial = 6, # This could also be a grid search
    # initial = knn_res,
    iter = 25,
    metrics = auc_acc_sens_spec,
    control = ctrl_bayes
  )

  best_loss_knn <- select_best(knn_res, "mn_log_loss") # Best based on loss
  best_accuracy_knn <- select_best(knn_res, "accuracy") # Best based on accuracy
  best_sens_knn <- select_best(knn_res, "sens") # Best based on sensitivity
  best_spec_knn <- select_best(knn_res, "spec") # Best based on specificity
  best_auc_knn <- select_best(knn_res, "roc_auc") # Best based on auc
  best_precision_knn <- select_best(knn_res, "precision") # Best based on precision

  fin_knn <- Sys.time()

  ## XGBoost
  # load("../../ML_out/two_class/cv_simple/res_objects/xgb_res.Rda")
  ini_xgb <- Sys.time()
  parameters_xgb <- parameters(xgb_spec)
  parameters_xgb <- xgb_spec %>% parameters() %>% finalize(copd_ctrl_pred)

  xgb_res <- tune_bayes(
    xgb_wf,
    resamples = copd_ctrl_folds,
    param_info = parameters_xgb,
    initial = 6,
    # initial = xgb_res,
    iter = 25,
    control = ctrl_bayes,
    metrics = auc_acc_sens_spec
  )

  best_loss_xgb <- select_best(xgb_res, "mn_log_loss") # Best based on loss
  best_accuracy_xgb <- select_best(xgb_res, "accuracy") # Best based on accuracy
  best_sens_xgb <- select_best(xgb_res, "sens") # Best based on sensitivity
  best_spec_xgb <- select_best(xgb_res, "spec") # Best based on specificity
  best_auc_xgb <- select_best(xgb_res, "roc_auc") # Best based on auc
  best_precision_xgb <- select_best(xgb_res, "precision") # Best based on precision

  fin_xgb <- Sys.time()

  # FINALIZE MODELS AND GET METRICS ON RESAMPLINGS AND TEST
  ## Random Forest
  final_rf <- finalize_model(
    rf_spec,
    best_accuracy_rf
  )

  rf_wf_updated <- rf_wf %>%
    update_model(final_rf)

  rf_fit <- rf_wf_updated %>%
    fit(data = copd_ctrl_train_mrmr)

  rf_rs <- rf_fit %>%
    fit_resamples(
      resamples = copd_ctrl_folds,
      metrics = auc_acc_sens_spec,
      control = ctrl_res # to obatin the prediction column
    )

  ## Suppor Vector Machines: radial
  final_svm_r <- finalize_model(
    svm_r_spec,
    best_accuracy_svm_r
  )

  svm_r_wf_updated <- svm_r_wf %>%
    update_model(final_svm_r)

  svm_r_fit <- svm_r_wf_updated %>%
    fit(data = copd_ctrl_train_mrmr)

  svm_r_rs <- svm_r_fit %>%
    fit_resamples(
      resamples = copd_ctrl_folds,
      metrics = auc_acc_sens_spec,
      control = ctrl_res # to obatin the prediction column
    )

  ## Suppor Vector Machines: poly
  final_svm_p <- finalize_model(
    svm_p_spec,
    best_accuracy_svm_p
  )

  svm_p_wf_updated <- svm_p_wf %>%
    update_model(final_svm_p)

  svm_p_fit <- svm_p_wf_updated %>%
    fit(data = copd_ctrl_train_mrmr)

  svm_p_rs <- svm_p_fit %>%
    fit_resamples(
      resamples = copd_ctrl_folds,
      metrics = auc_acc_sens_spec,
      control = ctrl_res # to obatin the prediction column
    )

  ## Penalized Regression Model
  final_en <- finalize_model(
    en_spec,
    best_accuracy_en
  )

  en_wf_updated <- en_wf %>%
    update_model(final_en)

  en_fit <- en_wf_updated %>%
    fit(data = copd_ctrl_train_mrmr)

  en_rs <- en_fit %>%
    fit_resamples(
      resamples = copd_ctrl_folds,
      metrics = auc_acc_sens_spec,
      control = ctrl_res # to obatin the prediction column
    )

  ## k-Nearest Neighbours
  final_knn <- finalize_model(
    knn_spec,
    best_accuracy_knn
  )

  knn_wf_updated <- knn_wf %>%
    update_model(final_knn)

  knn_fit <- knn_wf_updated %>%
    fit(data = copd_ctrl_train_mrmr)

  knn_rs <- knn_fit %>%
    fit_resamples(
      resamples = copd_ctrl_folds,
      metrics = auc_acc_sens_spec,
      control = ctrl_res # to obatin the prediction column
    )

  ## xgboost
  final_xgb <- finalize_model(
    xgb_spec,
    best_accuracy_xgb
  )

  xgb_wf_updated <- xgb_wf %>%
    update_model(final_xgb)

  xgb_fit <- xgb_wf_updated %>%
    fit(data = copd_ctrl_train_mrmr)

  xgb_rs <- xgb_fit %>%
    fit_resamples(
      resamples = copd_ctrl_folds,
      metrics = auc_acc_sens_spec,
      control = ctrl_res # to obatin the prediction column
    )

  times <- list("rf" = fin_rf-ini_rf , "svm_r" = fin_svm_r-ini_svm_r,
            "svm_p" = fin_svm_p-ini_svm_p, "pen_reg" = fin_en - ini_en,
            "knn" = fin_knn-ini_knn, "xgb" = fin_xgb-ini_xgb)

  # RESULTS
  results <- list("train_res" = NULL , "all_train" = NULL, "test" = NULL,
                  "miss_samples_train_res" = NULL, "miss_samples_all_train" = NULL,
                  "miss_samples_test" = NULL, "times" = times)
  r_train <- list("rf" = NULL , "svm_r" = NULL, "svm_p" = NULL, "pen_reg" = NULL,
            "knn" = NULL, "xgb" = NULL)
  r_all_train <- list("rf" = NULL , "svm_r" = NULL, "svm_p" = NULL, "pen_reg" = NULL,
            "knn" = NULL, "xgb" = NULL, "stack" = NULL)
  r_test <- list("rf" = NULL , "svm_r" = NULL, "svm_p" = NULL, "pen_reg" = NULL,
            "knn" = NULL, "xgb" = NULL, "stack" = NULL)
  s_train <- list("rf" = NULL , "svm_r" = NULL, "svm_p" = NULL, "pen_reg" = NULL,
            "knn" = NULL, "xgb" = NULL, "stack" = NULL)
  s_all_train <- list("rf" = NULL , "svm_r" = NULL, "svm_p" = NULL, "pen_reg" = NULL,
            "knn" = NULL, "xgb" = NULL, "stack" = NULL)
  s_test <- list("rf" = NULL , "svm_r" = NULL, "svm_p" = NULL, "pen_reg" = NULL,
            "knn" = NULL, "xgb" = NULL, "stack" = NULL)
  classifiers <- list(rf_rs, svm_r_rs, svm_p_rs, en_rs, knn_rs, xgb_rs)
  # fits <- list(rf_fit, svm_r_fit, svm_p_fit, en_fit, knn_fit, xgb_fit, st_fit)
  fits <- list(rf_fit, svm_r_fit, svm_p_fit, en_fit, knn_fit, xgb_fit)

  # Training
  for(i in 1:length(classifiers)){

          classifier <- classifiers[[i]]
          pred_train <- bind_rows(classifier$.predictions, .id = "column_label")

          pred_train <-  pred_train %>% rename(
              fold = column_label,
              COPD = .pred_COPD,
              CTRL = .pred_CTRL,
              prediction = .pred_class,
              observation = dis_condition)
          pred_train <- pred_train[,-7]

          sample_identifier <- filter(pred_train,
                          observation == "COPD" & prediction == "CTRL"
                          |observation == "CTRL" & prediction == "COPD") %>% select(c(fold,.row))

          missclasified_samples_train <- as.data.frame(table(sample_identifier$.row))
          missclasified_samples_train <- missclasified_samples_train %>%
                                          rename(
                                            row_id = Var1)
          rownames(missclasified_samples_train) <- rownames(copd_ctrl_train_mrmr[
                    as.integer(levels(missclasified_samples_train$row_id)),])

          loss_auc_train <-  pred_train %>%
              group_by(fold) %>%
              auc_loss(truth = observation, COPD) %>%
              group_by(.metric) %>%
              summarise(
                mean = mean(.estimate, na.rm = TRUE),
                sd = sd(.estimate, na.rm = TRUE)
              )

          all_metrics <- pred_train %>%
              group_by(fold) %>%
              conf_mat(observation, prediction) %>%
              mutate(summary_tbl = lapply(conf_mat, summary)) %>%
              unnest(summary_tbl)

          metrics_train <- all_metrics %>%
              group_by(.metric) %>%
              summarise(
                  mean = mean(.estimate, na.rm = TRUE),
                  sd = sd(.estimate, na.rm = TRUE)
               )

          metrics_train <- rbind(metrics_train, loss_auc_train)
          matrix_train <- conf_mat_resampled(classifier)
          r_train[[i]] <- list("metrics" = metrics_train, "matrix" = matrix_train)
          s_train[[i]] <- missclasified_samples_train
      }

  results$train_res <- r_train
  results$miss_samples_train_res <- s_train

  # TRAIN & TEST
  for(i in 1:length(fits)){

          fit <- fits[[i]]

          # ALL TRAIN
          pred_all_train <- fit %>%
                  predict(copd_ctrl_train_mrmr) %>%
                  bind_cols(copd_ctrl_train_mrmr)

          matrix_all_train <- pred_all_train %>%
                  conf_mat(truth = dis_condition, estimate = .pred_class)

          metrics_all_train <- summary(pred_all_train %>%
                  conf_mat(truth = dis_condition, estimate = .pred_class))

          loss_auc_all_train <- fit %>%
                  predict(copd_ctrl_train_mrmr, type ="prob") %>%
                  bind_cols(copd_ctrl_train_mrmr) %>%
                  auc_loss(truth = dis_condition, .pred_COPD)

          metrics_all_train <- rbind(metrics_all_train, loss_auc_all_train)

          misclassified_samples_all_train <- rownames(filter(pred_all_train,
                                           dis_condition == "COPD" & .pred_class == "CTRL"
                                           |dis_condition == "CTRL" & .pred_class == "COPD"))

          # TEST
          pred_test <- fit %>%
                  predict(copd_ctrl_test) %>%
                  bind_cols(copd_ctrl_test)

          matrix_test <- pred_test %>%
                  conf_mat(truth = dis_condition, estimate = .pred_class)
          metrics_test <- summary(pred_test %>%
                  conf_mat(truth = dis_condition, estimate = .pred_class))

          loss_auc_test <- fit %>%
                  predict(copd_ctrl_test, type ="prob") %>%
                  bind_cols(copd_ctrl_test) %>%
                  auc_loss(truth = dis_condition, .pred_COPD)

          metrics_test <- rbind(metrics_test, loss_auc_test)

          misclassified_samples_test <- rownames(filter(pred_test,
                                           dis_condition == "COPD" & .pred_class == "CTRL"
                                           |dis_condition == "CTRL" & .pred_class == "COPD"))


          r_all_train[[i]] <- list("metrics" = metrics_all_train, "matrix" = matrix_all_train)
          s_all_train[[i]] <- misclassified_samples_all_train
          r_test[[i]] <- list("metrics" = metrics_test, "matrix" = matrix_test)
          s_test[[i]] <- misclassified_samples_test



      }

  # ALL TRAIN
  results$all_train <- r_all_train
  results$miss_samples_all_train <- s_all_train
  # TEST
  results$test <- r_test
  results$miss_samples_test <- s_test


  return(results)

}


num_iterations <- as.numeric(num_iterations)
num_genes <- as.numeric(num_genes)

# Now, let's loop through the number of iterations and randomly select genes each time
for (i in num_iterations:(num_iterations+1)) {

  # Randomly sample gene indices
  gene_indices <- sample(ncol(copd_ctrl_train), size = num_genes)
  # Select the corresponding columns from the original data frame
  copd_ctrl_train_subset <- copd_ctrl_train[, gene_indices]
  copd_ctrl_train_subset$dis_condition <- copd_ctrl_train$dis_condition
  copd_ctrl_pred <- select(copd_ctrl_train_subset, -dis_condition)
  results <- ML_models(copd_ctrl_train_subset)

  print(paste("Results of iter", i, sep = ""))
  print(results)
  # Save as a Rdata file
  save(results,
    file=paste("../../ML_out/two_class/optm/random_",num_genes,"/results_",i,".Rda", sep= ""))

}
