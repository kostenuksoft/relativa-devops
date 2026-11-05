import http from 'k6/http';

const baseUrl = __ENV.BASE_URL;
const paths = __ENV.PATHS.split(',');
const rate = Number(__ENV.RATE);
const vus = Number(__ENV.VUS);

export const options = {
  discardResponseBodies: true,
  noConnectionReuse: true,
  scenarios: {
    gateway: {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration: __ENV.DURATION,
      preAllocatedVUs: vus,
      maxVUs: vus,
    },
  },
};

export default function () {
  const path = paths[Math.floor(Math.random() * paths.length)];
  http.get(`${baseUrl}${path}`, { tags: { name: path } });
}
