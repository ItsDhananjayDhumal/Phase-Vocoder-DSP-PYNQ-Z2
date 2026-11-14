# Hook for every synthesis/implementation step: Vivado 2023.2 crashed in its
# thread pool on this host, so run single-threaded.
set_param general.maxThreads 1
