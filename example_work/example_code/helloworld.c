// Simple helloworld program in C with timing
#include <stdio.h>
#include <time.h>

int main() {
    // Start the clock
    clock_t start_time = clock();

    // Your original code
    printf("Hello, World!\n");

    // Stop the clock
    clock_t end_time = clock();

    // Calculate elapsed time in seconds
    double time_taken = (double)(end_time - start_time) / CLOCKS_PER_SEC;

    // Print the result
    printf("Execution time: %f seconds\n", time_taken);

    return 0;
}
