import {
  Route,
  Router,
  useLocation,
  useNavigate,
} from '@solidjs/router';
import {
  ErrorBoundary,
  Show,
  Suspense,
  createEffect,
  createMemo,
  type JSX,
  lazy,
} from 'solid-js';
import { render } from 'solid-js/web';

import '#ui/App.css';

import { ROUTE_PATH } from '#ui/constants';
import { useAuth } from '#ui/hooks';
import { AuthLayout, MainLayout } from '#ui/layouts';
import { AuthProvider } from '#ui/providers';
import { ToastProvider } from '#ui/components';

const SignIn = lazy(() => import('#ui/pages/SignIn'));
const SignUp = lazy(() => import('#ui/pages/SignUp'));
const ForgotPassword = lazy(() => import('#ui/pages/ForgotPassword'));
const ResetPassword = lazy(() => import('#ui/pages/ResetPassword'));
const VerifyEmail = lazy(() => import('#ui/pages/VerifyEmail'));
const Users = lazy(() => import('#ui/pages/Users'));
const Tasks = lazy(() => import('#ui/pages/Tasks'));
const Files = lazy(() => import('#ui/pages/Files'));
const Tenants = lazy(() => import('#ui/pages/Tenants'));
const Profile = lazy(() => import('#ui/pages/Profile'));
const Dashboard = lazy(() => import('#ui/pages/Dashboard'));
const AuditLogs = lazy(() => import('#ui/pages/AuditLogs'));
const MailTemplates = lazy(() => import('#ui/pages/MailTemplates'));
const AiChat = lazy(() => import('#ui/pages/AiChat'));
const AiAdmin = lazy(() => import('#ui/pages/AiAdmin'));
const Organizations = lazy(() => import('#ui/pages/Organizations'));
const Projects = lazy(() => import('#ui/pages/Projects'));
const Agents = lazy(() => import('#ui/pages/Agents'));
const MfaSettings = lazy(() => import('#ui/pages/MfaSettings'));
const NotFound = lazy(() => import('#ui/pages/NotFound'));

function BootFallback() {
  return (
    <div class="flex min-h-screen items-center justify-center bg-base-100 text-sm text-base-content/60">
      加载中…
    </div>
  );
}

function Protected(props: { children?: JSX.Element }) {
  const [auth] = useAuth();
  const navigate = useNavigate();

  createEffect(() => {
    if (auth.status === 'unverified') {
      navigate(ROUTE_PATH.signIn, { replace: true });
    }
  });

  return (
    <Show when={auth.status === 'verified'} fallback={<BootFallback />}>
      <MainLayout>{props.children}</MainLayout>
    </Show>
  );
}

/** Redirects non-admin users away from admin-only pages. */
function AdminGate(props: { children?: JSX.Element }) {
  const [auth] = useAuth();
  const navigate = useNavigate();

  createEffect(() => {
    if (auth.status === 'verified' && !auth.user?.admin) {
      navigate(ROUTE_PATH.profile, { replace: true });
    }
  });

  return <>{props.children}</>;
}

function Root(props: { children?: JSX.Element }) {
  const location = useLocation();
  const navigate = useNavigate();
  const pathname = createMemo(() => location.pathname);

  createEffect(() => {
    if (pathname() === ROUTE_PATH.root) {
      navigate(ROUTE_PATH.index, { replace: true });
    }
  });

  return (
    <AuthProvider>
      <ToastProvider>
        <ErrorBoundary
        fallback={(err, reset) => (
          <div class="flex min-h-screen flex-col items-center justify-center gap-4 p-6">
            <p class="text-error">页面出错了。</p>
            <pre class="max-w-lg overflow-auto rounded bg-base-200 p-3 text-xs">
              {err instanceof Error ? err.message : String(err)}
            </pre>
            <button type="button" class="btn btn-primary" onClick={reset}>
              重试
            </button>
          </div>
        )}
      >
        <Suspense fallback={<BootFallback />}>{props.children}</Suspense>
        </ErrorBoundary>
      </ToastProvider>
    </AuthProvider>
  );
}

const root = document.getElementById('root');
if (root) {
  render(
    () => (
      <Router root={Root}>
        <Route
          path={ROUTE_PATH.signIn}
          component={() => (
            <AuthLayout>
              <SignIn />
            </AuthLayout>
          )}
        />
        <Route
          path={ROUTE_PATH.signUp}
          component={() => (
            <AuthLayout>
              <SignUp />
            </AuthLayout>
          )}
        />
        <Route
          path={ROUTE_PATH.forgotPassword}
          component={() => (
            <AuthLayout>
              <ForgotPassword />
            </AuthLayout>
          )}
        />
        <Route
          path={ROUTE_PATH.resetPassword}
          component={() => (
            <AuthLayout>
              <ResetPassword />
            </AuthLayout>
          )}
        />
        <Route
          path={ROUTE_PATH.verifyEmail}
          component={() => (
            <AuthLayout>
              <VerifyEmail />
            </AuthLayout>
          )}
        />
        <Route path={ROUTE_PATH.root} component={Protected}>
          <Route
            path={ROUTE_PATH.dashboard}
            component={() => (
              <AdminGate>
                <Dashboard />
              </AdminGate>
            )}
          />
          <Route
            path={ROUTE_PATH.users}
            component={() => (
              <AdminGate>
                <Users />
              </AdminGate>
            )}
          />
          <Route
            path={ROUTE_PATH.auditLogs}
            component={() => (
              <AdminGate>
                <AuditLogs />
              </AdminGate>
            )}
          />
          <Route path={ROUTE_PATH.aiChat} component={AiChat} />
          <Route
            path={ROUTE_PATH.aiAdmin}
            component={() => (
              <AdminGate>
                <AiAdmin />
              </AdminGate>
            )}
          />
          <Route
            path={ROUTE_PATH.mailTemplates}
            component={() => (
              <AdminGate>
                <MailTemplates />
              </AdminGate>
            )}
          />
          <Route
            path={ROUTE_PATH.tasks}
            component={() => (
              <AdminGate>
                <Tasks />
              </AdminGate>
            )}
          />
          <Route path={ROUTE_PATH.files} component={Files} />
          <Route
            path={ROUTE_PATH.tenants}
            component={() => (
              <AdminGate>
                <Tenants />
              </AdminGate>
            )}
          />
          <Route
            path={ROUTE_PATH.organizations}
            component={() => (
              <AdminGate>
                <Organizations />
              </AdminGate>
            )}
          />
          <Route
            path={ROUTE_PATH.projects}
            component={() => (
              <AdminGate>
                <Projects />
              </AdminGate>
            )}
          />
          <Route
            path={ROUTE_PATH.agents}
            component={() => (
              <AdminGate>
                <Agents />
              </AdminGate>
            )}
          />
          <Route
            path={ROUTE_PATH.mfaSettings}
            component={() => (
              <AdminGate>
                <MfaSettings />
              </AdminGate>
            )}
          />
          <Route path={ROUTE_PATH.profile} component={Profile} />
        </Route>
        <Route path="*" component={NotFound} />
      </Router>
    ),
    root,
  );
}
