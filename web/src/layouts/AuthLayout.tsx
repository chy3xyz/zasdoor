import type { JSX } from 'solid-js';

function AuthLayout(props: { children?: JSX.Element }) {
  return (
    <div class="flex min-h-screen items-center justify-center bg-base-200 p-4">
      <div class="w-full max-w-md">{props.children}</div>
    </div>
  );
}

export default AuthLayout;
