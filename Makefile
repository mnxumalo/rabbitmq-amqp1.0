PROJECT = rabbitmq_amqp1_0
PROJECT_DESCRIPTION = AMQP 1.0 support for RabbitMQ

define PROJECT_ENV
[
	    {default_user, "guest"},
	    {default_vhost, <<"/">>},
	    {protocol_strict_mode, false}
	  ]
endef

define PROJECT_APP_EXTRA_KEYS
	{broker_version_requirements, []}
endef

BUILD_DEPS = rabbitmq_codegen
DEPS = rabbit_common rabbit amqp_client amqp10_common
TEST_DEPS = rabbitmq_ct_helpers rabbitmq_ct_client_helpers amqp10_client

DEP_EARLY_PLUGINS = rabbit_common/mk/rabbitmq-early-plugin.mk
DEP_PLUGINS = rabbit_common/mk/rabbitmq-plugin.mk

ELIXIR_LIB_DIR = $(shell elixir -e 'IO.puts(:code.lib_dir(:elixir))')
 ifeq ($(ERL_LIBS),)
     ERL_LIBS = $(ELIXIR_LIB_DIR)
 else
     ERL_LIBS := $(ERL_LIBS):$(ELIXIR_LIB_DIR)
 endif

.DEFAULT_GOAL = all
$(PROJECT).d:: $(EXTRA_SOURCES)

# FIXME: Use erlang.mk patched for RabbitMQ, while waiting for PRs to be
# reviewed and merged.

ERLANG_MK_REPO = https://github.com/rabbitmq/erlang.mk.git
ERLANG_MK_COMMIT = rabbitmq-tmp

include rabbitmq-components.mk
include erlang.mk

# --------------------------------------------------------------------
# Framing sources generation.
# --------------------------------------------------------------------

clean:: clean-extra-sources

clean-extra-sources:
	$(gen_verbose) rm -f $(EXTRA_SOURCES)

distclean:: distclean-dotnet-tests distclean-java-tests

distclean-dotnet-tests:
	$(gen_verbose) cd test/system_SUITE_data/dotnet-tests && \
		rm -rf bin obj && \
		rm -f project.lock.json TestResult.xml

distclean-java-tests:
	$(gen_verbose) cd test/system_SUITE_data/java-tests && mvn clean
