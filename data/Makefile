# Plot the benchmark CSVs into each dataset's figures/ directory.
#
#   make                     every dataset
#   make main-text           only the main-text dataset
#   make appendix            only the appendix dataset
#   make list                what would be plotted, and with which plotter
#   make clean               remove every figures/ directory
#   make FLAGS='--logy'      override the plotting flags for this run
#
# A figure depends on its CSV *and* on the script that drew it, so editing the plotter redraws the
# figures rather than leaving them silently stale. A dataset keeping its own plot_latency.py is
# plotted with that one, which is how an archived result stays reproducible after the shared script
# moves on; everything else uses the one beside this Makefile.

PY    := python3
FLAGS := --pct 100

# Sweep directories are named YYYYMMDD; matched by shape rather than by a year.
DATED_CSVS := $(wildcard 20[0-9][0-9][0-1][0-9][0-3][0-9]/*.csv)
MAIN_TEXT_CSVS := $(wildcard data-main-text/*.csv)
APPENDIX_CSVS := $(wildcard data-appendix/*.csv)
CSVS := $(DATED_CSVS) $(MAIN_TEXT_CSVS) $(APPENDIX_CSVS)

# The plotter a dataset is drawn with: its own if it has one, else the shared one.
plotter = $(if $(wildcard $(dir $(1))plot_latency.py),$(dir $(1))plot_latency.py,plot_latency.py)
figure  = $(dir $(1))figures/$(notdir $(1:.csv=.png))

FIGURES := $(foreach c,$(CSVS),$(call figure,$(c)))
MAIN_TEXT_FIGURES := $(foreach c,$(MAIN_TEXT_CSVS),$(call figure,$(c)))
APPENDIX_FIGURES := $(foreach c,$(APPENDIX_CSVS),$(call figure,$(c)))
DATED_DIRS := $(sort $(patsubst %/,%,$(dir $(DATED_CSVS))))

.PHONY: all main-text appendix list clean $(DATED_DIRS)

all: $(FIGURES)

main-text: $(MAIN_TEXT_FIGURES)

appendix: $(APPENDIX_FIGURES)

# One rule per CSV, so each figure knows both its data and the script that draws it.
define PLOT_RULE
$(call figure,$(1)): $(1) $(call plotter,$(1))
	@mkdir -p $$(@D)
	$$(PY) $(call plotter,$(1)) $$< -o $$@ $$(FLAGS)
endef
$(foreach c,$(CSVS),$(eval $(call PLOT_RULE,$(c))))

# `make 20260812` plots just that dataset.
define DIR_RULE
$(1): $(foreach c,$(filter $(1)/%,$(CSVS)),$(call figure,$(c)))
endef
$(foreach d,$(DATED_DIRS),$(eval $(call DIR_RULE,$(d))))

list:
	@$(foreach c,$(CSVS),printf '  %-62s <- %s\n' '$(call figure,$(c))' '$(call plotter,$(c))';)

clean:
	rm -rf 20[0-9][0-9][0-1][0-9][0-3][0-9]/figures
	rm -rf data-main-text/figures data-appendix/figures
