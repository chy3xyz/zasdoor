import { A } from '@solidjs/router';

import { ROUTE_PATH } from '#ui/constants';

function NotFound() {
  return (
    <div class="flex min-h-screen flex-col items-center justify-center gap-4 bg-base-200">
      <p class="text-7xl font-bold text-base-content/20">404</p>
      <p class="text-lg">页面不存在</p>
      <A href={ROUTE_PATH.index} class="btn btn-primary">
        返回首页
      </A>
    </div>
  );
}

export default NotFound;
