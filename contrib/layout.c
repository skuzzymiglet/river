/*
 * Tiled layout for river, implemented in understandable, simple, commented code.
 * Reading this code should help you get a basic understanding of how to use
 * river-layout to create a basic layout generator and how your layouts can
 * depend on values of river-options.
 *
 * Q: Wow, this is a lot of code just for a layout!
 * A: No, it really is not. Most of the code here is just generic Wayland client
 *    boilerplate. The actual layout part is pretty small.
 *
 * Q: Can I use this to port dwm layouts to river?
 * A: Yes you can! You just need to replace the logic in layout_handle_layout_demand().
 *    You don't even need to fully understand the protocol if all you want to
 *    do is just port some simple layouts.
 *
 * Q: I have no idea how any of this works.
 * A: If all you want to do is create simple layouts, you do not need to
 *    understand the Wayland parts of the code. If you still want to understand
 *    it and are already familiar with how Wayland clients work, read the
 *    protocol. If you are new to writing Wayland client code, you can read
 *    https://wayland-book.com, then read the protocol.
 *
 * Q: How do I build this?
 * A: To build, you need to generate the header and code of the layout protocol
 *    extension and link against them. This is achieved with the following
 *    commands (You may want to setup a build system).
 *
 *        wayland-scanner private-code < river-layout-unstable-v1.xml > river-layout-unstable-v1.c
 *        wayland-scanner client-header < river-layout-unstable-v1.xml > river-layout-unstable-v1.h
 *        wayland-scanner private-code < river-options-unstable-v1.xml > river-options-unstable-v1.c
 *        wayland-scanner client-header < river-options-unstable-v1.xml > river-options-unstable-v1.h
 *        gcc -Wall -Wextra -Wpedantic -Wno-unused-parameter -c -o layout.o layout.c
 *        gcc -Wall -Wextra -Wpedantic -Wno-unused-parameter -c -o river-layout-unstable-v1.o river-layout-unstable-v1.c
 *        gcc -Wall -Wextra -Wpedantic -Wno-unused-parameter -c -o river-options-unstable-v1.o river-options-unstable-v1.c
 *        gcc -o layout layout.o river-layout-unstable-v1.o river-options-unstable-v1.o -lwayland-client
 */

#include<assert.h>
#include<stdbool.h>
#include<stdio.h>
#include<stdlib.h>
#include<string.h>

#include<wayland-client.h>
#include<wayland-client-protocol.h>

#include"river-layout-unstable-v1.h"
#include"river-options-unstable-v1.h"

struct Context
{
	struct wl_display  *display;
	struct wl_registry *registry;

	struct wl_list outputs;

	struct zriver_layout_manager_v1 *layout_manager;
	struct zriver_options_manager_v1 *options_manager;

	bool run;
	int ret;
};

struct Output
{
	struct wl_list link;

	struct Context          *context;
	struct wl_output        *output;
	struct zriver_layout_v1 *layout;

	struct zriver_option_handle_v1 *main_amount_option;
	struct zriver_option_handle_v1 *main_factor_option;
	struct zriver_option_handle_v1 *view_padding_option;
	struct zriver_option_handle_v1 *outer_padding_option;

	uint32_t main_amount;
	double   main_factor;
	uint32_t view_padding;
	uint32_t outer_padding;
};

/* A few macros to indulge the inner glibc user. */
#define MIN(a, b) ( a < b ? a : b )
#define MAX(a, b) ( a > b ? a : b )
#define CLAMP(a, b, c) ( MIN(MAX(b, c), MAX(MIN(b, c), a)) )

static void layout_handle_layout_demand (void *data, struct zriver_layout_v1 *zriver_layout_v1,
		uint32_t view_amount, uint32_t width, uint32_t height, uint32_t serial)
{
	struct Output *output = (struct Output *)data;

	/* Simple tiled layout with no frills.
	 *
	 * If you want to create your own simple layout, just rip the following
	 * code out and replace it with your own logic. All content un-aware
	 * dynamic tiling layouts you know, for example from dwm, can be easily
	 * ported to river this way. If you want to create layouts that are
	 * content aware, meaning they react to the currently visible windows,
	 * you have to create handlers for the advertise_view and advertise_done
	 * events. Happy hacking!
	 */
	width -= 2 * output->outer_padding, height -= 2 * output->outer_padding;
	const double main_factor = CLAMP(output->main_factor, 0.1, 0.9);
	unsigned int main_size, stack_size, view_x, view_y, view_width, view_height;
	if ( output->main_amount == 0 )
	{
		main_size  = 0;
		stack_size = width;
	}
	else if ( view_amount <= output->main_amount )
	{
		main_size  = width;
		stack_size = 0;
	}
	else
	{
		main_size  = width * main_factor;
		stack_size = width - main_size;
	}
	for (unsigned int i = 0; i < view_amount; i++)
	{
		if ( i < output->main_amount ) /* main area. */
		{
			view_x      = 0;
			view_width  = main_size;
			view_height = height / MIN(output->main_amount, view_amount);
			view_y      = i * view_height;
		}
		else /* Stack area. */
		{
			view_x      = main_size;
			view_width  = stack_size;
			view_height = height / ( view_amount - output->main_amount);
			view_y      = (i - output->main_amount) * view_height;
		}

		zriver_layout_v1_push_view_dimensions(output->layout, serial,
				view_x + output->view_padding + output->outer_padding,
				view_y + output->view_padding + output->outer_padding,
				view_width - (2*output->view_padding),
				view_height - (2*output->view_padding));
	}

	zriver_layout_v1_commit(output->layout, serial);
}

static void layout_handle_namespace_in_use (void *data, struct zriver_layout_v1 *zriver_layout_v1)
{
	/* Oh no, the namespace we choose is already used by another client!
	 * All we can do now is destroy the river_layout object. Because we are
	 * lazy, we just abort and let our cleanup mechanism destroy it. A more
	 * sophisticated client could instead destroy only the one single
	 * affected river_layout object and recover from this mishap. Writing
	 * such a client is left as an exercise for the reader.
	 */
	struct Context *context = (struct Context *)data;
	fputs("Namespace already in use.\n", stderr);
	context->run = false;
}

static void noop () { }

static const struct zriver_layout_v1_listener layout_listener = {
	.namespace_in_use = layout_handle_namespace_in_use,
	.layout_demand    = layout_handle_layout_demand,
	.advertise_view   = noop,
	.advertise_done   = noop,
};

static void main_amount_handle_change (void *data, struct zriver_option_handle_v1 *handle, uint32_t value)
{
	struct Output *output = (struct Output *)data;
	output->main_amount = value;

	/* Our layout depends on this value. We need to signal the compositor
	 * that one of the parameters we use to generate the layout has changed.
	 * It may then decide to start a new layout demand.
	 */
	zriver_layout_v1_parameters_changed(output->layout);
}

static const struct zriver_option_handle_v1_listener main_amount_listener = {
	.unset        = noop,
	.int_value    = noop,
	.uint_value   = main_amount_handle_change,
	.fixed_value  = noop,
	.string_value = noop,
};

static void main_factor_handle_change (void *data, struct zriver_option_handle_v1 *handle, wl_fixed_t value)
{
	struct Output *output = (struct Output *)data;
	output->main_factor = wl_fixed_to_double(value);
	zriver_layout_v1_parameters_changed(output->layout);
}

static const struct zriver_option_handle_v1_listener main_factor_listener = {
	.unset        = noop,
	.int_value    = noop,
	.uint_value   = noop,
	.fixed_value  = main_factor_handle_change,
	.string_value = noop,
};

static void view_padding_handle_change (void *data, struct zriver_option_handle_v1 *handle, uint32_t value)
{
	struct Output *output = (struct Output *)data;
	output->view_padding = value;
	zriver_layout_v1_parameters_changed(output->layout);
}

static const struct zriver_option_handle_v1_listener view_padding_listener = {
	.unset        = noop,
	.int_value    = noop,
	.uint_value   = view_padding_handle_change,
	.fixed_value  = noop,
	.string_value = noop,
};

static void outer_padding_handle_change (void *data, struct zriver_option_handle_v1 *handle, uint32_t value)
{
	struct Output *output = (struct Output *)data;
	output->outer_padding = value;
	zriver_layout_v1_parameters_changed(output->layout);
}

static const struct zriver_option_handle_v1_listener outer_padding_listener = {
	.unset        = noop,
	.int_value    = noop,
	.uint_value   = outer_padding_handle_change,
	.fixed_value  = noop,
	.string_value = noop,
};

static void configure_output (struct Output *output)
{
	/* The namespace of the layout is how the compositor chooses what layout
	 * to use. It can be any arbitrary string. It should describe roughly
	 * what kind of layout your client will create, so here we use "tile".
	 */
	output->layout = zriver_layout_manager_v1_get_river_layout(
			output->context->layout_manager, output->output, "tile");
	zriver_layout_v1_add_listener(output->layout, &layout_listener, output);

	/* The amount of main views and other such values are communicated using
	 * river-options. You can have an arbitrary amount of options which hold
	 * arbitrary values, but here we just use the default ones. These are
	 * automatically created by river for each output and already set, which
	 * means we do not have to handle the cases of them having either no
	 * type or a wrong type. However if you want to use other custom options,
	 * you will have to do so.
	 *
	 * The added complexity and verbosity of using a separate listener for
	 * each value is needed because of C and because of the way listeners
	 * work in libwayland. This could be solved more nicely with other
	 * wayland libraries and by using other languages, but here we are...
	 */
	output->main_amount_option = zriver_options_manager_v1_get_option_handle(
		output->context->options_manager, "main_amount", output->output);
	zriver_option_handle_v1_add_listener(output->main_amount_option,
		&main_amount_listener, output);
	output->main_factor_option = zriver_options_manager_v1_get_option_handle(
		output->context->options_manager, "main_factor", output->output);
	zriver_option_handle_v1_add_listener(output->main_factor_option,
		&main_factor_listener, output);
	output->view_padding_option = zriver_options_manager_v1_get_option_handle(
		output->context->options_manager, "view_padding", output->output);
	zriver_option_handle_v1_add_listener(output->view_padding_option,
		&view_padding_listener, output);
	output->outer_padding_option = zriver_options_manager_v1_get_option_handle(
		output->context->options_manager, "outer_padding", output->output);
	zriver_option_handle_v1_add_listener(output->outer_padding_option,
		&outer_padding_listener, output);
}

static bool create_output (struct Context *context, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version)
{
	struct Output *output = calloc(1, sizeof(struct Output));
	if ( output == NULL )
		return false;

	output->output = wl_registry_bind(registry, name, &wl_output_interface, 3);
	output->context = context;
	output->layout = NULL;

	output->main_amount_option   = NULL;
	output->main_factor_option   = NULL;
	output->view_padding_option  = NULL;
	output->outer_padding_option = NULL;

	output->main_amount   = 1;
	output->main_factor   = 0.6;
	output->view_padding  = 10;
	output->outer_padding = 10;

	/* If we already have the river_layout_manager and the river_options_manager,
	 * we can get a river_layout for this output.
	 */
	if ( context->layout_manager != NULL && context->options_manager != NULL )
		configure_output(output);

	wl_list_insert(&context->outputs, &output->link);
	return true;
}

static void destroy_output (struct Output *output)
{
	if ( output->layout != NULL )
		zriver_layout_v1_destroy(output->layout);
	if ( output->main_amount_option != NULL )
		zriver_option_handle_v1_destroy(output->main_amount_option);
	if ( output->main_factor_option != NULL )
		zriver_option_handle_v1_destroy(output->main_factor_option);
	if ( output->view_padding_option != NULL )
		zriver_option_handle_v1_destroy(output->view_padding_option);
	if ( output->outer_padding_option != NULL )
		zriver_option_handle_v1_destroy(output->outer_padding_option);
	wl_output_destroy(output->output);
	wl_list_remove(&output->link);
	free(output);
}

static void destroy_all_outputs (struct Context *context)
{
	struct Output *output, *tmp;
	wl_list_for_each_safe(output, tmp, &context->outputs, link)
		destroy_output(output);
}

static void registry_handle_global (void *data, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version)
{
	struct Context *context = (struct Context *)data;

	if (! strcmp(interface, zriver_layout_manager_v1_interface.name))
		context->layout_manager = wl_registry_bind(registry, name, &zriver_layout_manager_v1_interface, 1);
	else if (! strcmp(interface, zriver_options_manager_v1_interface.name))
		context->options_manager = wl_registry_bind(registry, name, &zriver_options_manager_v1_interface, 1);
	else if (! strcmp(interface, wl_output_interface.name))
	{
		if (! create_output(context, registry, name, interface, version))
			goto error;
	}

	return;
error:
	context->run = false;
	context->ret = EXIT_FAILURE;
}

static const struct wl_registry_listener registry_listener = {
	.global        = registry_handle_global,
	.global_remove = noop
};

static bool init_wayland (struct Context *context)
{
	if ( NULL == (context->display = wl_display_connect(NULL)) )
	{
		fputs("Can not connect to Wayland server.\n", stderr);
		return false;
	}

	wl_list_init(&context->outputs);

	context->registry = wl_display_get_registry(context->display);
	assert(context->registry);
	wl_registry_add_listener(context->registry, &registry_listener, context);

	wl_display_roundtrip(context->display);

	if ( context->layout_manager == NULL )
	{
		fputs("Wayland compositor does not support river-layout-unstable-v1.\n", stderr);
		return false;
	}

	if ( context->options_manager == NULL )
	{
		fputs("Wayland compositor does not support river-options-unstable-v1.\n", stderr);
		return false;
	}

	/* If outputs were registered before both river_layout_manager and
	 * river_options_manager where available, they won't have a river_layout
	 * nor the option handles, so we need to create those here.
	 */
	struct Output *output;
	wl_list_for_each(output, &context->outputs, link)
		if ( output->layout == NULL )
			configure_output(output);

	return true;
}

static void finish_wayland (struct Context *context)
{
	if ( context->display == NULL )
		return;

	destroy_all_outputs(context);

	if ( context->layout_manager != NULL )
		zriver_layout_manager_v1_destroy(context->layout_manager);
	if ( context->options_manager != NULL )
		zriver_options_manager_v1_destroy(context->options_manager);

	wl_registry_destroy(context->registry);
	wl_display_disconnect(context->display);
}

static void run (struct Context *context)
{
	context->ret = EXIT_SUCCESS;
	while ( context->run && wl_display_dispatch(context->display) != -1 );
	fputs("Connection lost.\n", stderr);
}

int main (int argc, char *argv[])
{
	struct Context context = { 0 };
	context.ret = EXIT_FAILURE;
	context.run = true;

	if (init_wayland(&context))
		run(&context);

	finish_wayland(&context);
	return context.ret;
}

