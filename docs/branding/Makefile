PYTHON ?= python3
BRANDING_VENV ?= .venv-branding
BRANDING_PYTHON := $(BRANDING_VENV)/bin/python3
BRANDING_PIP := $(BRANDING_VENV)/bin/pip

.PHONY: branding branding-png branding-svg branding-setup

branding: branding-png branding-svg

branding-setup:
	$(PYTHON) -m venv $(BRANDING_VENV)
	$(BRANDING_PIP) install -r requirements.txt

branding-png:
	$(BRANDING_PYTHON) ../../scripts/generate_branding_png.py

branding-svg:
	$(BRANDING_PYTHON) ../../scripts/generate_branding_svg.py
