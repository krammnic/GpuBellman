#include "bellman.cuh"
#include "../main.h"

void printCudaDevice(){
    int dev = 0;
    cudaSetDevice(dev);
    cudaDeviceProp devProps;
    if (cudaGetDeviceProperties(&devProps, dev) == 0)
    {
        printf("Using device %d:\n", dev);
        printf("%s; global mem: %dB; compute v%d.%d; clock: %d kHz\n",
               devProps.name, (int)devProps.totalGlobalMem,
               (int)devProps.major, (int)devProps.minor,
               (int)devProps.clockRate);
    }
}

int runBellmanFordOnGPU(const char *file, int blockSize, int debug) {

    std::string inputFile=file;
    int BLOCK_SIZE = blockSize;
    int DEBUG = debug;
    int MAX_VAL = std::numeric_limits<int>::max();

    std::vector<int> V, I, E, W;
    //Load data from files
    loadVector((inputFile + "_V.csv").c_str(), V);
    loadVector((inputFile + "_I.csv").c_str(), I);
    loadVector((inputFile + "_E.csv").c_str(), E);
    loadVector((inputFile + "_W.csv").c_str(), W);

    if(DEBUG){
        cout << "V = "; printVector(V); cout << endl;
        cout << "I = "; printVector(I); cout << endl;
        cout << "E = "; printVector(E); cout << endl;
        cout << "W = "; printVector(W); cout << endl;
    }

    //output. Rewrite this part with Cuda kernel
    std::vector<int> D(V.size(), MAX_VAL); //Shortest path of V[i] from source
    std::vector<int> pred(V.size(), -1); // Predecessor vetex of V[i]

    //Set source vertex and predecessor
    D[0] = 0;
    pred[0] = 0;

    //int *in_V = V.data();
    //int *in_I = I.data();
    //int *in_E = E.data();
    //int *in_W = W.data();

    int N = I.size();
    int BLOCKS = 1;
    BLOCKS = (N + BLOCK_SIZE - 1) / BLOCK_SIZE;
    printCudaDevice();
    cout << "Blocks : " << BLOCKS << " Block size : " << BLOCK_SIZE << endl;

    int *d_in_V;
    int *d_in_I;
    int *d_in_E;
    int *d_in_W;
    int *d_out_D; // Final shortest distance
    int *d_out_Di; // Used in keep track of the distance during one single execution of the kernel
    int *d_out_P; // Final parent
    int *d_out_Pi; // Used in keep track of the parent during one single execution of the kernel

    //allocate memory
    cudaMalloc((void**) &d_in_V, V.size() *sizeof(int));
    cudaMalloc((void**) &d_in_I, I.size() *sizeof(int));
    cudaMalloc((void**) &d_in_E, E.size() *sizeof(int));
    cudaMalloc((void**) &d_in_W, W.size() *sizeof(int));

    cudaMalloc((void**) &d_out_D, D.size() *sizeof(int));
    cudaMalloc((void**) &d_out_Di, D.size() *sizeof(int));
    cudaMalloc((void**) &d_out_P, pred.size() *sizeof(int));
    cudaMalloc((void**) &d_out_Pi, pred.size() *sizeof(int));

    //copy to device memory
    cudaMemcpy(d_in_V, V.data(), V.size() *sizeof(int), cudaMemcpyHostToDevice);
    cudaMemcpy(d_in_I, I.data(), I.size() *sizeof(int), cudaMemcpyHostToDevice);
    cudaMemcpy(d_in_E, E.data(), E.size() *sizeof(int), cudaMemcpyHostToDevice);
    cudaMemcpy(d_in_W, W.data(), W.size() *sizeof(int), cudaMemcpyHostToDevice);

    cudaMemcpy(d_out_D, D.data(), D.size() *sizeof(int), cudaMemcpyHostToDevice);
    cudaMemcpy(d_out_P, pred.data(), pred.size() *sizeof(int), cudaMemcpyHostToDevice);
    cudaMemcpy(d_out_Di, D.data(), D.size() *sizeof(int), cudaMemcpyHostToDevice);
    cudaMemcpy(d_out_Pi, pred.data(), pred.size() *sizeof(int), cudaMemcpyHostToDevice);

    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    cout << "Running Bellman Ford on GPU!" << endl;
    cudaEventRecord(start, 0);
    //Do binary search to find index of each element in E. This won't be necessary if the vertex starts from 0.
    //But in the case of DIMACS vertex start from 1. so in the relax kernel index of the destination vertex is needed to update the D array.
    //E.size() - because we need to replace each E[i] with its index of V[i]
    //0, V.size()-1 - for binary search of V array with each E[i] to find index
    updateIndexOfEdges<<<BLOCKS, BLOCK_SIZE>>>(E.size(), d_in_V, d_in_E, 0, V.size()-1);

    // Bellman ford
    for (int round = 1; round < V.size(); round++) {
        if(DEBUG){
            cout<< "***** round = " << round << " ******* " << endl;
        }
        relax<<<BLOCKS, BLOCK_SIZE>>>(N, MAX_VAL, d_in_V, d_in_I, d_in_E, d_in_W, d_out_D, d_out_Di, d_out_P, d_out_Pi);
        updateDistance<<<BLOCKS, BLOCK_SIZE>>>(N, d_in_V, d_in_I, d_in_E, d_in_W, d_out_D, d_out_Di, d_out_P, d_out_Pi);
    }

    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    cout << "Completed Bellman Ford on GPU!" << endl;
    float elapsedTime;
    cudaEventElapsedTime(&elapsedTime, start, stop);

    int *out_path = new int[V.size()];
    int *out_pred = new int[V.size()];

    cudaMemcpy(out_path, d_out_D, D.size()*sizeof(int), cudaMemcpyDeviceToHost);
    cudaMemcpy(out_pred, d_out_P, pred.size()*sizeof(int), cudaMemcpyDeviceToHost);

    if(DEBUG) {
        cout << "Shortest Path : " << endl;
        for (int i = 0; i < D.size(); i++) {
            cout << "from " << V[0] << " to " << V[i] << " = " << out_path[i] << " predecessor = " << out_pred[i]
                 << std::endl;
        }
    }

    // Create output file name by parsing the input filename and extracting the last string :
    std::string delimiter = "/";
    size_t pos = 0;
    std::string token;
    while ((pos = inputFile.find(delimiter)) != std::string::npos) {
        token = inputFile.substr(0, pos);
        inputFile.erase(0, pos + delimiter.length());
    }
    storeResult(("../output/" + inputFile + "_SP.csv").c_str(),V, out_path, out_pred);
    cout << "Results written to " << ("../output/" + inputFile + "_SP.csv").c_str() << endl;
    cout << "** average time elapsed : " << elapsedTime << " milli seconds** " << endl;

    free(out_pred);
    free(out_path);
    cudaFree(d_in_V);
    cudaFree(d_in_I);
    cudaFree(d_in_E);
    cudaFree(d_in_W);
    cudaFree(d_out_D);
    cudaFree(d_out_P);
    cudaFree(d_out_Di);
    cudaFree(d_out_Pi);
    return 0;
}