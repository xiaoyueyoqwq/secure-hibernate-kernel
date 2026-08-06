#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <glib.h>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
  FlMethodChannel* activation_channel;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static const gchar* kWindowTitle = "Secure Hibernate";
static const gchar* kActivationChannel =
    "io.github.xiaoyueyoqwq.secure-hibernate-manager/activation";

static gchar* application_asset_path(const gchar* asset_name) {
  g_autofree gchar* executable_path =
      g_file_read_link("/proc/self/exe", nullptr);
  if (executable_path != nullptr) {
    g_autofree gchar* executable_directory =
        g_path_get_dirname(executable_path);
    return g_build_filename(executable_directory, asset_name, nullptr);
  }

  g_autofree gchar* working_directory = g_get_current_dir();
  return g_build_filename(working_directory, asset_name, nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window != nullptr) {
    gtk_window_present(self->window);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;
  g_autofree gchar* icon_path = application_asset_path("app-icon.png");
  GError* icon_error = nullptr;
  if (!gtk_window_set_icon_from_file(window, icon_path, &icon_error)) {
    g_warning("Unable to load application icon %s: %s", icon_path,
              icon_error == nullptr ? "unknown error" : icon_error->message);
    g_clear_error(&icon_error);
  }
  gtk_window_set_title(window, kWindowTitle);
  gtk_window_set_decorated(window, FALSE);
  gtk_window_set_default_size(window, 1180, 760);
  gtk_widget_set_size_request(GTK_WIDGET(window), 760, 560);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->activation_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      kActivationChannel, FL_METHOD_CODEC(codec));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

static gboolean command_opens_updates(gchar** arguments, int argument_count) {
  for (int index = 1; index < argument_count; index++) {
    if (g_strcmp0(arguments[index], "--updates") == 0) {
      return TRUE;
    }
  }
  return FALSE;
}

// Implements GApplication::command_line.
static int my_application_command_line(
    GApplication* application,
    GApplicationCommandLine* command_line) {
  MyApplication* self = MY_APPLICATION(application);
  int argument_count = 0;
  g_auto(GStrv) arguments =
      g_application_command_line_get_arguments(command_line, &argument_count);
  const gboolean open_updates =
      command_opens_updates(arguments, argument_count);

  if (self->window == nullptr) {
    g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
    self->dart_entrypoint_arguments = g_strdupv(arguments + 1);
    g_application_activate(application);
  } else {
    if (open_updates && self->activation_channel != nullptr) {
      fl_method_channel_invoke_method(self->activation_channel, "openUpdates",
                                      nullptr, nullptr, nullptr, nullptr);
    }
    gtk_window_present(self->window);
  }
  return 0;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_object(&self->activation_channel);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->command_line = my_application_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_HANDLES_COMMAND_LINE,
                                     nullptr));
}
