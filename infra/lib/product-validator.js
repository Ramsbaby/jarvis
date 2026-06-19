/**
 * Product Validator Module
 *
 * 오답승격 클러스터 cl-4cc5f6afa4de4e5d 방지 가드
 * - 제품 성분표 URL 확인
 * - 제품 재고 상태 확인
 * - 추천 전 검증 로직
 *
 * 사용 사례:
 *   1. 사용자가 제품 추천을 요청하기 전에 이 모듈을 호출
 *   2. 제품 성분표 URL + 재고 상태를 반환
 *   3. 둘 다 확인되면 추천 진행, 아니면 차단
 */

const fs = require('fs').promises;
const path = require('path');

class ProductValidator {
  constructor(options = {}) {
    this.dataDir = options.dataDir || path.join(process.env.HOME || '/tmp', '.jarvis', 'data', 'products');
    this.cacheDir = options.cacheDir || path.join(process.env.HOME || '/tmp', '.jarvis', 'cache', 'products');
    this.cacheTTL = options.cacheTTL || 3600000; // 1 hour default
    this.productDatabase = options.productDatabase || {}; // in-memory cache
    this.lastCacheTime = {};
  }

  /**
   * 제품 성분표 및 재고 정보 조회
   * @param {string} productId - 제품 ID (예: "PID_001" 또는 "제품명")
   * @param {Object} options - 조회 옵션
   * @returns {Promise<{
   *   success: boolean,
   *   productId: string,
   *   name: string,
   *   ingredientUrl: string,
   *   ingredients: string[],
   *   stockStatus: 'IN_STOCK' | 'LOW_STOCK' | 'OUT_OF_STOCK' | 'UNKNOWN',
   *   lastUpdated: string,
   *   warning: string | null,
   *   error: string | null
   * }>}
   */
  async validateProduct(productId, options = {}) {
    const timestamp = new Date().toISOString();
    const result = {
      success: false,
      productId,
      name: null,
      ingredientUrl: null,
      ingredients: [],
      stockStatus: 'UNKNOWN',
      lastUpdated: timestamp,
      warning: null,
      error: null
    };

    try {
      // 1. 캐시 확인
      const cached = await this._getFromCache(productId);
      if (cached && !options.skipCache) {
        return {
          ...cached,
          lastUpdated: timestamp,
          warning: '캐시된 데이터 (최근 1시간 이내)'
        };
      }

      // 2. 제품 데이터 조회
      const product = await this._lookupProduct(productId);
      if (!product) {
        result.error = `제품 '${productId}'을(를) 데이터베이스에서 찾을 수 없음`;
        return result;
      }

      result.name = product.name || product.productName;
      result.productId = product.id || productId;

      // 3. 성분표 URL 확인
      if (!product.ingredientUrl && !product.ingredient_url && !product.ingredients_url) {
        result.warning = '성분표 URL이 등록되지 않았습니다. 수동 확인 필요';
      } else {
        result.ingredientUrl = product.ingredientUrl || product.ingredient_url || product.ingredients_url;
      }

      // 4. 성분 데이터 추출 (URL이 있으면 파싱 시도)
      if (result.ingredientUrl) {
        try {
          result.ingredients = await this._parseIngredients(result.ingredientUrl, productId);
        } catch (err) {
          result.warning = `성분 파싱 실패: ${err.message}. 수동 확인 필요`;
        }
      }

      // 5. 재고 상태 확인
      const stockInfo = await this._checkStock(productId);
      result.stockStatus = stockInfo.status || 'UNKNOWN';
      if (stockInfo.quantity !== undefined) {
        result.stockQuantity = stockInfo.quantity;
      }
      if (stockInfo.lastUpdated) {
        result.stockLastUpdated = stockInfo.lastUpdated;
      }

      // 6. 재고 상태 기반 경고
      if (result.stockStatus === 'OUT_OF_STOCK') {
        result.warning = result.warning
          ? `${result.warning}; 품절 상태`
          : '제품이 현재 품절 상태입니다';
      } else if (result.stockStatus === 'LOW_STOCK') {
        result.warning = result.warning
          ? `${result.warning}; 재고 부족`
          : '제품 재고가 부족합니다';
      }

      result.success = true;

      // 7. 캐시에 저장
      await this._saveToCache(productId, result);

      return result;

    } catch (err) {
      result.error = `제품 검증 중 오류 발생: ${err.message}`;
      console.error(`[ProductValidator] Error validating ${productId}:`, err);
      return result;
    }
  }

  /**
   * 여러 제품 일괄 검증
   * @param {string[]} productIds
   * @param {Object} options
   * @returns {Promise<Object[]>}
   */
  async validateProducts(productIds, options = {}) {
    return Promise.all(
      productIds.map(id => this.validateProduct(id, options))
    );
  }

  /**
   * 추천 전 검증 가드 (높은 수준의 체크)
   * @param {string} productId - 추천하려는 제품 ID
   * @param {Object} options
   * @returns {Promise<{
   *   canRecommend: boolean,
   *   reason: string,
   *   validation: Object
   * }>}
   */
  async canRecommend(productId, options = {}) {
    const validation = await this.validateProduct(productId, options);

    const result = {
      canRecommend: false,
      reason: '',
      validation
    };

    if (!validation.success) {
      result.reason = `제품 정보 조회 실패: ${validation.error}`;
      return result;
    }

    // 1. 성분표 필수 확인
    if (!validation.ingredientUrl && !options.skipIngredientCheck) {
      result.reason = '성분표 URL이 없습니다. 먼저 성분표 URL을 등록해야 합니다.';
      return result;
    }

    // 2. 성분 데이터 필수 확인
    if (!validation.ingredients || validation.ingredients.length === 0) {
      if (!options.skipIngredientCheck) {
        result.reason = '성분 데이터를 파싱할 수 없습니다. 성분표를 수동으로 확인해주세요.';
        return result;
      }
    }

    // 3. 재고 상태 확인
    if (validation.stockStatus === 'OUT_OF_STOCK') {
      result.reason = '제품이 품절 상태입니다. 재입고 후 추천해주세요.';
      return result;
    }

    // 4. 모든 검증 통과
    result.canRecommend = true;
    if (validation.warning) {
      result.reason = `경고: ${validation.warning}`;
    } else {
      result.reason = '검증 완료. 추천 진행 가능';
    }

    return result;
  }

  /**
   * 추천 응답 생성 시 이 함수로 감싸기
   * @param {string} productId
   * @param {Function} recommendationFn - 실제 추천 로직 함수
   * @param {Object} options
   * @returns {Promise}
   */
  async withValidation(productId, recommendationFn, options = {}) {
    const guardResult = await this.canRecommend(productId, options);

    if (!guardResult.canRecommend) {
      return {
        success: false,
        error: guardResult.reason,
        recommendation: null,
        validation: guardResult.validation
      };
    }

    try {
      const recommendation = await recommendationFn(guardResult.validation);
      return {
        success: true,
        recommendation,
        validation: guardResult.validation,
        guard: {
          passed: true,
          reason: guardResult.reason
        }
      };
    } catch (err) {
      return {
        success: false,
        error: `추천 생성 중 오류: ${err.message}`,
        recommendation: null,
        validation: guardResult.validation
      };
    }
  }

  /**
   * 프라이빗: 제품 데이터 조회
   * 실제 구현에서는 데이터베이스나 외부 API 연동
   */
  async _lookupProduct(productId) {
    // TODO: 실제 구현
    // - DB 쿼리 (MongoDB, PostgreSQL 등)
    // - 또는 외부 API 호출
    // - 또는 JSON 파일 로드

    // 임시 구현: 메모리 캐시 및 파일 조회
    if (this.productDatabase[productId]) {
      return this.productDatabase[productId];
    }

    // 파일 기반 조회 시도
    try {
      const filePath = path.join(this.dataDir, `${productId}.json`);
      const data = await fs.readFile(filePath, 'utf-8');
      return JSON.parse(data);
    } catch {
      // 파일 없음: 기본값 반환 (실제로는 실패해야 함)
      return null;
    }
  }

  /**
   * 프라이빗: 성분 파싱
   */
  async _parseIngredients(ingredientUrl, productId) {
    // TODO: 실제 구현
    // - URL에서 성분 데이터 스크래핑
    // - 또는 캐시된 성분 데이터 조회

    // 임시: URL 검증만 수행
    if (!ingredientUrl.startsWith('http')) {
      throw new Error('유효하지 않은 URL 형식');
    }

    // 실제 구현에서는 여기서 웹 스크래핑이나 API 호출
    // 예: cheerio로 HTML 파싱, 또는 상품 상세 API 호출

    return [];
  }

  /**
   * 프라이빗: 재고 상태 조회
   */
  async _checkStock(productId) {
    // TODO: 실제 구현
    // - 재고 시스템 API 호출
    // - 재고 데이터베이스 쿼리

    // 임시: UNKNOWN 반환
    return {
      status: 'UNKNOWN',
      quantity: null,
      lastUpdated: null
    };
  }

  /**
   * 프라이빗: 캐시에서 조회
   */
  async _getFromCache(productId) {
    const now = Date.now();
    const lastTime = this.lastCacheTime[productId] || 0;

    // TTL 확인
    if (now - lastTime > this.cacheTTL) {
      return null;
    }

    try {
      const cacheFile = path.join(this.cacheDir, `${productId}.json`);
      const data = await fs.readFile(cacheFile, 'utf-8');
      return JSON.parse(data);
    } catch {
      return null;
    }
  }

  /**
   * 프라이빗: 캐시에 저장
   */
  async _saveToCache(productId, data) {
    try {
      await fs.mkdir(this.cacheDir, { recursive: true });
      const cacheFile = path.join(this.cacheDir, `${productId}.json`);
      await fs.writeFile(cacheFile, JSON.stringify(data, null, 2));
      this.lastCacheTime[productId] = Date.now();
    } catch (err) {
      console.warn(`[ProductValidator] Failed to save cache for ${productId}:`, err.message);
    }
  }

  /**
   * 제품 데이터베이스 등록 (메모리)
   */
  registerProduct(productId, productData) {
    this.productDatabase[productId] = {
      id: productId,
      ...productData
    };
  }

  /**
   * 배치 등록
   */
  registerProducts(products) {
    products.forEach(p => {
      this.registerProduct(p.id || p.productId, p);
    });
  }

  /**
   * 캐시 초기화
   */
  async clearCache() {
    try {
      await fs.rm(this.cacheDir, { recursive: true, force: true });
      this.lastCacheTime = {};
    } catch (err) {
      console.warn('[ProductValidator] Failed to clear cache:', err.message);
    }
  }

  /**
   * 상태 리포트 (디버깅용)
   */
  getStatus() {
    return {
      dataDir: this.dataDir,
      cacheDir: this.cacheDir,
      cacheTTL: this.cacheTTL,
      productsInMemory: Object.keys(this.productDatabase).length,
      cachedAt: Object.keys(this.lastCacheTime).length
    };
  }
}

module.exports = ProductValidator;
