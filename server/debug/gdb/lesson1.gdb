# Lesson 1 Native query breakpoints. battle_nav.so is loaded after process start,
# therefore pending breakpoints are required.
set pagination off
set breakpoint pending on
set print pretty on

break l_query_cell
break battle_nav::GridMap::WorldToGrid
break battle_nav::GridMap::QueryWorld

printf "Lesson1 gdb breakpoints installed. Run with: run\n"
printf "When a breakpoint hits, useful commands: bt, info threads, p world, p position\n"
