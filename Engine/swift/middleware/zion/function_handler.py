from swift.common.swob import wsgify, HTTPInternalServerError, HTTPException
from swift.common.utils import get_logger
from zion.handlers import ProxyHandler
from zion.handlers import ComputeHandler
from zion.handlers import ObjectHandler
from zion.handlers.base import NotFunctionRequest
from distutils.util import strtobool
import redis


class FunctionHandlerMiddleware(object):

    def __init__(self, app, conf):
        self.app = app
        self.conf = conf
        self.exec_server = self.conf.get('execution_server')
        self.logger = get_logger(conf, name=self.exec_server +
                                 "-server Zion",
                                 log_route='function_handler')
        redis_host = self.conf.get('redis_host')
        redis_port = self.conf.get('redis_port')
        redis_db = self.conf.get('redis_db')
        self.redis_conn_pool = redis.ConnectionPool(host=redis_host,
                                                    port=redis_port,
                                                    db=redis_db)

        self.handler_class = self._get_handler(self.exec_server)

    def _get_handler(self, exec_server):
        """
        Generate Handler class based on execution_server parameter

        :param exec_server: Where this storlet_middleware is running.
                            This should value should be 'proxy' or 'compute'
        :raise ValueError: If exec_server is invalid
        """
        if exec_server == 'proxy':
            return ProxyHandler
        elif exec_server == 'compute':
            return ComputeHandler
        elif exec_server == 'object':
            return ObjectHandler
        else:
            raise ValueError('configuration error: execution_server must be '
                             'either proxy, object or compute but is %s' % exec_server)

    @wsgify
    def __call__(self, req):
        try:
            r = redis.Redis(connection_pool=self.redis_conn_pool)
            handler = self.handler_class(req, self.conf, self.app, self.logger, r)
            self.logger.debug('%s call in %s' % (req.method, req.path))

            return handler.handle_request()

        except NotFunctionRequest:
            self.logger.debug('No Zion Request, bypassing middleware')
            return req.get_response(self.app)

        except HTTPException:
            self.logger.exception('Zion execution failed')
            raise

        except Exception:
            self.logger.exception('Zion execution failed')
            raise HTTPInternalServerError(body='Unable to execute the requested operation: Zion execution failed\n')


def filter_factory(global_conf, **local_conf):
    """Standard filter factory to use the middleware with paste.deploy"""
    conf = global_conf.copy()
    conf.update(local_conf)
    # Common
    conf['execution_server'] = conf.get('execution_server')
    conf['functions_container'] = conf.get('functions_container', 'functions')
    conf['functions_visibility'] = strtobool(conf.get('functions_visibility', 'True'))
    # Paths
    conf['main_dir'] = conf.get('main_dir', '/opt/zion')
    # Worker paths
    conf['workers_dir'] = conf.get('workers_dir', 'workers')
    conf['java_runtime_dir'] = conf.get('java_runtime_dir', 'runtime/java')
    # Function Paths
    conf['functions_dir'] = conf.get('functions_dir', 'functions')
    conf['cache_dir'] = conf.get('cache_dir', 'cache')
    conf['log_dir'] = conf.get('log_dir', 'logs')
    conf['bin_dir'] = conf.get('bin_dir', 'bin')
    # Redis metastore
    conf['redis_host'] = conf.get('redis_host', 'localhost')
    conf['redis_port'] = int(conf.get('redis_port', 6379))
    conf['redis_db'] = int(conf.get('redis_db', 10))
    # Function defaults
    conf['default_function_timeout'] = int(conf.get('default_function_timeout', 10))
    conf['default_function_memory'] = int(conf.get('default_function_memory', 1024))
    conf['max_function_memory'] = int(conf.get('max_function_memory', 1024))
    # Compute Nodes
    conf['disaggregated_compute'] = strtobool(conf.get('disaggregated_compute', 'True'))
    conf['compute_nodes'] = conf.get('compute_nodes', 'localhost:8585')
    conf['docker_pool_dir'] = conf.get('docker_pool_dir', 'docker_pool')

    def swift_functions(app):
        return FunctionHandlerMiddleware(app, conf)

    return swift_functions
