#ifndef BLUESTORE_CLI_H
#define BLUESTORE_CLI_H

namespace bluestore {

int run(int argc, char** argv);
int list();
int clean();
int get();
int head();
int put();
int post();
int remove();

}

#endif
