ERL ?= erl
REL ?= rel
APP := auc_app

.PHONY: deps

all: deps
	@./rebar compile

rel: all
	@./rebar generate

app:
	@./rebar compile skip_deps=true

deps:
	@./rebar get-deps

clean:
	@./rebar clean

distclean: clean
	@./rebar delete-deps

docs:
	@erl -noshell -run edoc_run application '$(APP)' '"."' '[]'

build: rel
	@build_number="$$(expr $$(date +'%s') / 3600)"; \
		mv $(REL)/$(APP) $(REL)/$(APP).$$build_number; \
		if [ $$? -eq 0 ]; then \
		echo "Build successful, the build number is $$build_number ."; \
		else echo "Build failed, please check it ."; \
		fi;

buildclean:
	@rm -rf $(REL)/$(APP).*
