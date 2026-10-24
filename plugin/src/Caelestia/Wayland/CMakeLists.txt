qml_module(caelestia-wayland
    URI Caelestia.Wayland
    INCLUDE_PREFIX wayland
    SOURCES
        ironlandshortcut.cpp
        ironlandfocusgrab.cpp
        ironlandframecapture.cpp
        ironlandclipboardhistory.cpp
        ironlandcinemamode.cpp
        ironlanddisplayfilter.cpp
        ironlandvmlauncher.cpp
    LIBRARIES
        Qt::Gui
        Qt::GuiPrivate
        Qt::WaylandClient
    DEPENDENCIES
        Caelestia
)

caelestia_add_wayland_protocol(caelestia-wayland
    FILES
        "${CMAKE_SOURCE_DIR}/plugin/protocols/ironland-shortcuts-v1.xml"
        "${CMAKE_SOURCE_DIR}/plugin/protocols/ironland-focus-grab-v1.xml"
        "${CMAKE_SOURCE_DIR}/plugin/protocols/ironland-frame-capture-v1.xml"
        "${CMAKE_SOURCE_DIR}/plugin/protocols/ironland-clipboard-history-v1.xml"
        "${CMAKE_SOURCE_DIR}/plugin/protocols/ironland-cinema-mode-v1.xml"
        "${CMAKE_SOURCE_DIR}/plugin/protocols/ironland-display-filter-v1.xml"
        "${CMAKE_SOURCE_DIR}/plugin/protocols/ironland-vm-launch-v1.xml"
)
