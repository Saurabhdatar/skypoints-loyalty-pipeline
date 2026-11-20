.PHONY: test run
test:
	python -m unittest discover -s tests -v
run:
	PYTHONPATH=src python -m skypoints.cli --input data/sample --out out --as-of 2024-01-15
