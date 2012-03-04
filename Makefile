#
# Targets
#

REBAR=`which rebar`

.PHONY: build deps

all: deps build

clean:
	$(REBAR) clean

deps:
	$(REBAR) get-deps

build:
	$(REBAR) compile
	$(MAKE) xref

test: build
	$(REBAR) skip_deps=true eunit

package: all
	rm -rf rel/package
	$(REBAR) generate -f

doc:
	$(REBAR) skip_deps=true doc

#
# Run
#

DEPS=deps/*/ebin
ERL=exec erl -pa apps/poxy/ebin $(DEPS) -sname poxy

.PHONY: boot noboot

console: package
	rel/package/bin/poxy console

boot: build
	$(ERL) -s poxy

noboot: build
	$(ERL)

#
# Analysis
#

PLT=./plt/R15B.plt

WARNINGS=-Werror_handling \
  -Wrace_conditions \
  -Wunderspecs \
  -Wunmatched_returns

APPS=kernel stdlib sasl erts ssl \
  tools os_mon runtime_tools crypto \
  inets xmerl webtool snmp public_key \
  mnesia eunit syntax_tools compiler

build-plt: all
	dialyzer --build_plt --output_plt $(PLT) \
	  --apps $(APPS) $(DEPS)

dialyzer: build
	dialyzer apps/*/ebin --plt $(PLT) $(WARNINGS) \
	  | grep -v 'lager_not_running'

xref:
	$(REBAR) skip_deps=true xref

typer: build
	typer --annotate --plt $(PLT) -I deps/ -I apps/poxy/ -r apps/ 
