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

class HelloServiceV3(hello_v3_pb2_grpc.HelloServiceV3Servicer):
    def SayHello(self, request, context):
        greeting = request.greeting if request.greeting else 'World'
        return hello_v3_pb2.HelloResponseV3(reply=f'Hello from v3, {greeting}!')

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

    server.add_insecure_port('[::]:9000')
    server.start()
    print("gRPC Server running on port 9000...")
    server.wait_for_termination()

if __name__ == '__main__':
    serve()
