cmake_minimum_required(VERSION 3.22.1)
project(espiaodv C)
add_library(espiaodv SHARED espiao.c)
target_link_libraries(espiaodv log)
# Android 15+ em arm64 exige páginas de 16 KB.
target_link_options(espiaodv PRIVATE "-Wl,-z,max-page-size=16384")
