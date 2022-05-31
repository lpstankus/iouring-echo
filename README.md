# iouring-echo
A simple io_uring echo server, made just for exploring memory mapped ring buffers and IO with io_uring

I know that the ring buffer struct used here does not make any sense in the context, it just wastes file descriptors that could be used for new connections and we gain very little in return. In the end this was just a learning experiment and I wanted to write a ring buffer ¯\\\_(ツ)\_/¯
