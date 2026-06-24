import grpc
from concurrent import futures
import sys
import os

# Ensure the server directory is in the python path to find generated modules
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import hello_pb2
import hello_pb2_grpc
import hello_v3_pb2
import hello_v3_pb2_grpc

class HelloService(hello_pb2_grpc.HelloServiceServicer):
    def SayHello(self, request, context):
        greeting = request.greeting if request.HasField('greeting') else 'World'
        return hello_pb2.HelloResponse(reply=f'Hello from v2, {greeting}!')

    def SayHelloStream(self, request_iterator, context):
        for req in request_iterator:
            greeting = req.greeting if req.HasField('greeting') else 'World'
            yield hello_pb2.HelloResponse(reply=f'Hello stream, {greeting}!')

class HelloServiceV3(hello_v3_pb2_grpc.HelloServiceV3Servicer):
    def SayHello(self, request, context):
        greeting = request.greeting if request.greeting else 'World'
        return hello_v3_pb2.HelloResponseV3(reply=f'Hello from v3, {greeting}!')

    def SayMultiType(self, request, context):
        return hello_v3_pb2.MultiTypeResponse(
            reply=f'Got: {request.fString} {request.fInt32} {request.fBool}')

def serve():
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    hello_pb2_grpc.add_HelloServiceServicer_to_server(HelloService(), server)
    hello_v3_pb2_grpc.add_HelloServiceV3Servicer_to_server(HelloServiceV3(), server)

    # Add Reflection so grpcurl works easily without specifying proto files
    try:
        from grpc_reflection.v1alpha import reflection
        SERVICE_NAMES = (
            hello_pb2.DESCRIPTOR.services_by_name['HelloService'].full_name,
            hello_v3_pb2.DESCRIPTOR.services_by_name['HelloServiceV3'].full_name,
            reflection.SERVICE_NAME,
        )
        reflection.enable_server_reflection(SERVICE_NAMES, server)
        print("gRPC reflection enabled.")
    except ImportError:
        print("gRPC reflection not available. Install grpcio-reflection.")

    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9000
    bound = server.add_insecure_port(f'127.0.0.1:{port}')
    server.start()
    print(f'127.0.0.1:{bound}', flush=True)
    server.wait_for_termination()

if __name__ == '__main__':
    serve()
